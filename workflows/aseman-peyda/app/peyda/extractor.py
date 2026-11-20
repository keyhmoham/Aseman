"""Query → frame. GLiNER2 does the reading; a gazetteer checks its work.

`GlinerExtractor` loads a GLiNER2 checkpoint once (lazily, on a background
thread, so the server answers health checks while the model loads) and asks
for entities and classifications in a single forward pass:

    schema = model.create_schema()
        .entities(ENTITY_LABELS)
        .classification("domain", DOMAINS, multi_label=True)
        .classification("intent", INTENTS)

`HeuristicExtractor` is the same contract with no model: a lexicon and a city
gazetteer. It is the fallback while the model loads or when it cannot load,
and it is what the tests use. `HybridExtractor` runs GLiNER2 and fills what it
missed (a city it did not tag, a domain it was unsure of) from the lexicon, so
a search never goes out with an empty frame when the words were plain.
"""
from __future__ import annotations

import logging
import os
import threading
from typing import Any, Protocol

from .frame import DOMAINS, ENTITY_LABELS, INTENTS, QueryFrame, build_frame, normalize_text
from .lexicon import CITIES, DOMAIN_WORDS, find_cities, has_word

log = logging.getLogger("peyda.extractor")

MODEL_DEFAULT = "fastino/gliner2.5-multi-v1"


class Extractor(Protocol):
    def extract(self, text: str) -> QueryFrame: ...
    def status(self) -> dict[str, Any]: ...


# --------------------------------------------------------------------------
# Reading GLiNER2's answer (its shape varies with options and versions)
# --------------------------------------------------------------------------

def _entity_items(raw: Any) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for it in raw or []:
        if isinstance(it, str):
            out.append({"text": it, "confidence": 0.5})
        elif isinstance(it, dict) and it.get("text"):
            out.append({"text": str(it["text"]), "confidence": float(it.get("confidence", 0.5))})
    return out


def _labels(raw: Any) -> list[dict[str, Any]]:
    """A classification answer: 'a', ['a','b'], {'label','confidence'} or a list of those."""
    items = raw if isinstance(raw, list) else [raw]
    out: list[dict[str, Any]] = []
    for it in items:
        if isinstance(it, str):
            out.append({"name": it, "score": 0.5})
        elif isinstance(it, dict):
            name = it.get("label") or it.get("name") or it.get("text")
            if name:
                out.append({"name": str(name), "score": float(it.get("confidence", it.get("score", 0.5)))})
    return out


def parse_gliner(result: dict[str, Any]) -> tuple[dict[str, list[dict[str, Any]]], list[dict[str, Any]], str]:
    entities = {k: _entity_items(v) for k, v in (result.get("entities") or {}).items() if v}
    domains = [d for d in _labels(result.get("domain")) if d["name"] in DOMAINS]
    intents = [i for i in _labels(result.get("intent")) if i["name"] in INTENTS]
    intent = max(intents, key=lambda i: i["score"])["name"] if intents else "find"
    return entities, domains, intent


# --------------------------------------------------------------------------
# GLiNER2
# --------------------------------------------------------------------------

class GlinerExtractor:
    def __init__(self, model: str | None = None, threshold: float | None = None) -> None:
        self.model_name = model or os.environ.get("PEYDA_GLINER_MODEL", MODEL_DEFAULT)
        self.threshold = threshold if threshold is not None else float(os.environ.get("PEYDA_GLINER_THRESHOLD", "0.35"))
        self._model: Any = None
        self._schema: Any = None
        self._error: str = ""
        self._lock = threading.Lock()        # one forward pass at a time
        self._loading = threading.Lock()
        self._ready = threading.Event()

    # Loading runs once, off the request path.
    def start(self) -> None:
        threading.Thread(target=self._load, name="gliner-load", daemon=True).start()

    def _load(self) -> None:
        with self._loading:
            if self._ready.is_set():
                return
            try:
                from gliner2 import AutoExtractor  # heavy: torch

                model = AutoExtractor.from_pretrained(self.model_name)
                self._schema = (
                    model.create_schema()
                    .entities(ENTITY_LABELS)
                    .classification("domain", DOMAINS, multi_label=True, cls_threshold=0.3, top_k=4)
                    .classification("intent", INTENTS)
                )
                self._model = model
                self._ready.set()
                log.info("GLiNER2 ready: %s", self.model_name)
            except Exception as e:  # noqa: BLE001 - reported through status()
                self._error = f"{type(e).__name__}: {e}"
                log.exception("GLiNER2 failed to load")

    @property
    def ready(self) -> bool:
        return self._ready.is_set()

    def status(self) -> dict[str, Any]:
        return {"engine": "gliner2", "model": self.model_name, "ready": self.ready, "error": self._error}

    def raw(self, text: str) -> dict[str, Any]:
        if not self.ready:
            raise RuntimeError("the GLiNER2 model is not loaded yet")
        with self._lock:
            return self._model.extract(
                normalize_text(text), self._schema, threshold=self.threshold, include_confidence=True,
            )

    def extract(self, text: str) -> QueryFrame:
        entities, domains, intent = parse_gliner(self.raw(text))
        return build_frame(text, entities, domains, intent, source="gliner2")


# --------------------------------------------------------------------------
# No model: lexicon and gazetteer
# --------------------------------------------------------------------------

class HeuristicExtractor:
    def status(self) -> dict[str, Any]:
        return {"engine": "lexicon", "model": "", "ready": True, "error": ""}

    def extract(self, text: str) -> QueryFrame:
        norm = normalize_text(text)
        low = norm.lower()
        entities: dict[str, list[dict[str, Any]]] = {}
        cities = find_cities(low)
        if len(cities) >= 2:  # "Tehran to Mashhad": the order is the direction
            entities["origin"] = [{"text": cities[0], "confidence": 0.6}]
            entities["destination"] = [{"text": cities[1], "confidence": 0.6}]
        elif cities:
            entities["city"] = [{"text": cities[0], "confidence": 0.6}]
        scores: dict[str, float] = {}
        for domain, words in DOMAIN_WORDS.items():
            hits = sum(1 for w in words if has_word(low, w))
            if hits:
                scores[domain] = min(0.9, 0.4 + 0.15 * hits)
        domains = [{"name": d, "score": s} for d, s in scores.items()]
        intent = "cheapest" if any(w in low for w in ("ارزان", "cheap", "کمترین قیمت", "lowest price")) else "find"
        return build_frame(text, entities, domains, intent, source="lexicon")


class HybridExtractor:
    """GLiNER2 first; the lexicon fills what the model left empty."""

    def __init__(self, gliner: GlinerExtractor | None = None) -> None:
        self.gliner = gliner or GlinerExtractor()
        self.fallback = HeuristicExtractor()

    def start(self) -> None:
        self.gliner.start()

    def status(self) -> dict[str, Any]:
        s = self.gliner.status()
        s["fallback"] = "lexicon"
        return s

    def extract(self, text: str) -> QueryFrame:
        lex = self.fallback.extract(text)
        if not self.gliner.ready:
            lex.assumptions.append("the language model is still loading: read with the built-in lexicon")
            return lex
        try:
            frame = self.gliner.extract(text)
        except Exception as e:  # noqa: BLE001
            log.warning("GLiNER2 failed on a query: %s", e)
            lex.assumptions.append("the language model failed on this query: read with the built-in lexicon")
            return lex
        # Fill gaps only: the model's reading wins where it spoke.
        for key in ("city", "origin", "destination"):
            if key not in frame.slots and key in lex.slots:
                frame.slots[key] = lex.slots[key]
                frame.assumptions.append(f"{key} read from the city list, not the model")
        if not frame.domains:
            frame.domains = lex.domains
            if lex.domains:
                frame.assumptions.append("domains read from the lexicon, not the model")
        # "shopping" and "prices" are the model's catch-alls: on a flight, doctor or
        # pizza query they score high with nothing to buy and no rate in sight. Drop
        # one when the lexicon found a specific domain and not that one.
        names = frame.domain_names
        specific_in_lex = any(d["name"] not in ("shopping", "prices") for d in lex.domains)
        for generic, kept_by in (("shopping", lambda: frame.slots.get("brand") or frame.slots.get("price_max_toman") or frame.slots.get("price_min_toman")),
                                 ("prices", lambda: False)):
            if generic in names and len(names) > 1 and specific_in_lex and generic not in lex.domain_names and not kept_by():
                frame.domains = [d for d in frame.domains if d["name"] != generic]
                names = frame.domain_names
                frame.assumptions.append(f"{generic} dropped: the query names a service, not something to {'buy' if generic == 'shopping' else 'quote'}")
        if frame.intent == "find" and lex.intent == "cheapest":
            frame.intent = "cheapest"
        return frame


def make_extractor() -> Extractor:
    """PEYDA_EXTRACTOR=gliner2 (default) | lexicon (no model; tests, tiny machines)."""
    mode = os.environ.get("PEYDA_EXTRACTOR", "gliner2").lower()
    if mode == "lexicon":
        return HeuristicExtractor()
    ex = HybridExtractor()
    ex.start()
    return ex


__all__ = ["Extractor", "GlinerExtractor", "HeuristicExtractor", "HybridExtractor", "make_extractor", "parse_gliner", "CITIES"]
