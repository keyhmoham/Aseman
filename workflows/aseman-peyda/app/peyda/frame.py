"""The structured form of a query.

GLiNER2 reads a sentence and answers with *entities* (spans labelled by a
schema) and *classifications* (which domains, which intent). This module owns
that schema, and turns the raw answer into a `QueryFrame`: a small, typed,
normalised object (prices in Toman, Persian digits folded to ASCII, one value
per slot) that the gateway can turn into tool arguments and that the agent can
read, quote back and revise.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

# --------------------------------------------------------------------------
# The extraction schema (what GLiNER2 is asked for).
# --------------------------------------------------------------------------

ENTITY_LABELS: dict[str, str] = {
    "product": "the thing the person wants to find, buy, book or learn about: an item, dish, service, topic or title",
    "brand": "a brand, manufacturer, model line or shop name",
    "city": "an Iranian city, province or neighbourhood the request is about",
    "origin": "the city or place a trip starts from",
    "destination": "the city or place a trip goes to",
    "price_max": "the highest price or budget the person accepts",
    "price_min": "the lowest price the person accepts",
    "date": "a date, day or time expression such as tomorrow, next Thursday or 5 Mehr",
    "person": "the name of a person, such as a doctor, author or actor",
    "specialty": "a medical or professional specialty or field",
    "organization": "a company, site or organisation",
    "quantity": "a size, count or duration such as 60 metres, 2 nights or 3 people",
}

DOMAINS: dict[str, str] = {
    "shopping": "buying products or comparing shop prices",
    "classifieds": "used goods or classified ads",
    "real_estate": "homes and land for sale or rent",
    "cars": "buying, selling or pricing cars",
    "food": "restaurants, dishes, groceries and food delivery",
    "travel_tickets": "flights, trains, buses and other tickets between cities",
    "stays": "hotels, villas and places to stay",
    "maps": "places, addresses, directions and traffic",
    "health": "doctors, clinics, medicines and appointments",
    "books": "books and audiobooks",
    "courses": "online courses and learning",
    "jobs": "job openings and salaries",
    "freelance": "freelance projects and freelancers",
    "software": "apps, software and games to download",
    "prices": "gold, coin, currency and crypto prices",
    "stocks": "the stock exchange, funds and company filings",
    "news": "news and current events",
    "media": "films, series, video, TV, radio, cinema and event tickets",
    "weather_time": "weather, dates, holidays and prayer times",
    "reference": "word meanings, encyclopedia and blog articles",
    "law": "laws, regulations and taxes",
    "sports": "sports scores and tables",
}

INTENTS: dict[str, str] = {
    "find": "find or list matching things",
    "cheapest": "find the lowest price or best deal",
    "compare": "compare options or prices",
    "check": "look up a fact, status, availability or a current value",
    "learn": "understand, read about or get the meaning of something",
}

SLOT_LABELS = tuple(ENTITY_LABELS)

# --------------------------------------------------------------------------
# Text normalisation
# --------------------------------------------------------------------------

_FOLD = str.maketrans(
    "۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩يكۀ٫٬،",
    "01234567890123456789یکه.,,",
)


def normalize_text(text: str) -> str:
    """Folds Persian and Arabic-Indic digits to ASCII and Arabic letter forms
    to Persian ones, and collapses whitespace. Half-spaces are kept."""
    out = (text or "").translate(_FOLD)
    out = out.replace("‏", "").replace("‎", "")
    return re.sub(r"\s+", " ", out).strip()


_UNITS = {
    "میلیارد": 10**9, "billion": 10**9, "milliard": 10**9,
    "میلیون": 10**6, "million": 10**6, "mil": 10**6,
    "هزار": 10**3, "thousand": 10**3,
}
_WORD_NUMBERS = {
    "یک": 1, "دو": 2, "سه": 3, "چهار": 4, "پنج": 5, "شش": 6, "هفت": 7, "هشت": 8, "نه": 9, "ده": 10,
    "یازده": 11, "دوازده": 12, "سیزده": 13, "چهارده": 14, "پانزده": 15, "شانزده": 16, "هفده": 17,
    "هجده": 18, "نوزده": 19, "بیست": 20, "سی": 30, "چهل": 40, "پنجاه": 50, "شصت": 60, "هفتاد": 70,
    "هشتاد": 80, "نود": 90, "صد": 100, "یکصد": 100, "دویست": 200, "سیصد": 300, "پانصد": 500,
}
_NUMBER = re.compile(r"\d+(?:[.,]\d+)*")


def parse_amount_toman(text: str) -> int | None:
    """'under 20 million toman' / '۲۰ میلیون' / 'بیست میلیون' → 20_000_000.

    Prices on the Iranian web are quoted in Toman; a figure marked Rial
    (ریال) is divided by ten. Returns None when no amount can be read."""
    t = normalize_text(text).lower()
    if not t:
        return None
    value: float | None = None
    m = _NUMBER.search(t)
    if m:
        raw = m.group(0)
        # "1,500,000" thousands separators vs "2.5" decimals
        if raw.count(",") >= 1 and ("." not in raw) and all(len(p) == 3 for p in raw.split(",")[1:]):
            value = float(raw.replace(",", ""))
        else:
            value = float(raw.replace(",", "."))
    else:
        for word, n in _WORD_NUMBERS.items():
            if re.search(rf"(?<![\w]){word}(?![\w])", t):
                value = float(n)
                break
    if value is None:
        return None
    mult = 1
    for word, factor in _UNITS.items():
        if word in t:
            mult = max(mult, factor) if mult != 1 else factor
    amount = value * mult
    if "ریال" in t or "rial" in t:
        amount /= 10
    return int(round(amount))


_AMOUNT = r"([\d.,]+(?:\s*(?:میلیارد|میلیون|هزار|billion|million|thousand))?(?:\s*(?:تومان|toman|ریال|rial))?)"
_MAX_PAT = re.compile(
    r"(?:زیر|کمتر از|کمتر ?از|تا سقف|حداکثر|نهایتا|نهایتاً|تا|under|below|less than|up to|max(?:imum)?|at most)\s*" + _AMOUNT,
    re.I,
)
_MIN_PAT = re.compile(
    r"(?:بالای|بیشتر از|بیشتر ?از|حداقل|از|above|over|more than|at least|min(?:imum)?)\s*" + _AMOUNT,
    re.I,
)

# Words that carry no search meaning once the slots are lifted out.
_FILLER = {
    "ارزان", "ارزانترین", "ارزان‌ترین", "بهترین", "لطفا", "لطفاً", "میخوام", "می‌خوام", "میخواهم", "می‌خواهم",
    "دنبال", "پیدا", "کن", "کنید", "بده", "بدید", "برام", "برایم", "یه", "یک", "را", "رو", "در", "به", "از", "با",
    "the", "a", "an", "me", "please", "find", "show", "get", "i", "want", "need", "looking", "for", "cheapest",
    "best", "in", "near", "under", "below", "to", "from", "cheap", "cheaper", "ارزانتر", "ارزان‌تر",
}


# --------------------------------------------------------------------------
# The frame
# --------------------------------------------------------------------------

@dataclass
class QueryFrame:
    text: str
    normalized: str = ""
    entities: dict[str, list[dict[str, Any]]] = field(default_factory=dict)  # label → [{"text","confidence"}]
    domains: list[dict[str, Any]] = field(default_factory=list)              # [{"name","score"}]
    intent: str = "find"
    slots: dict[str, Any] = field(default_factory=dict)
    source: str = "gliner2"
    assumptions: list[str] = field(default_factory=list)

    @property
    def domain_names(self) -> list[str]:
        return [d["name"] for d in self.domains]

    def to_dict(self) -> dict[str, Any]:
        return {
            "text": self.text, "normalized": self.normalized, "entities": self.entities,
            "domains": self.domains, "intent": self.intent, "slots": self.slots,
            "source": self.source, "assumptions": self.assumptions,
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "QueryFrame":
        return cls(
            text=str(d.get("text", "")), normalized=str(d.get("normalized", "")),
            entities=dict(d.get("entities") or {}), domains=list(d.get("domains") or []),
            intent=str(d.get("intent") or "find"), slots=dict(d.get("slots") or {}),
            source=str(d.get("source") or "gliner2"), assumptions=list(d.get("assumptions") or []),
        )

    def brief(self) -> dict[str, Any]:
        """What the agent needs to see: no confidences, no spans."""
        return {"text": self.text, "domains": self.domain_names, "intent": self.intent, "slots": self.slots}


def _best(entities: dict[str, list[dict[str, Any]]], label: str) -> str | None:
    items = entities.get(label) or []
    if not items:
        return None
    return str(max(items, key=lambda e: e.get("confidence", 0.0))["text"]).strip() or None


def build_frame(
    text: str,
    entities: dict[str, list[dict[str, Any]]],
    domains: list[dict[str, Any]],
    intent: str,
    source: str = "gliner2",
) -> QueryFrame:
    """Turns raw extractor output into a normalised frame."""
    norm = normalize_text(text)
    slots: dict[str, Any] = {}
    for label in SLOT_LABELS:
        v = _best(entities, label)
        if v:
            slots[label] = normalize_text(v)

    # Prices: patterns in the sentence are more reliable than span labels.
    for label, pattern in (("price_max", _MAX_PAT), ("price_min", _MIN_PAT)):
        found = pattern.search(norm)
        raw = found.group(1) if found else slots.get(label)
        amount = parse_amount_toman(raw) if raw else None
        if amount:
            slots[label + "_toman"] = amount
        slots.pop(label, None)
    if slots.get("price_min_toman") and slots.get("price_max_toman") and slots["price_min_toman"] >= slots["price_max_toman"]:
        slots.pop("price_min_toman")

    if not slots.get("product"):
        residue = strip_known(norm, slots)
        if residue:
            slots["product"] = residue
    ordered = sorted(domains, key=lambda d: -float(d.get("score", 0)))
    return QueryFrame(
        text=text, normalized=norm, entities=entities, domains=ordered,
        intent=intent if intent in INTENTS else "find", slots=slots, source=source,
    )


def strip_known(norm: str, slots: dict[str, Any]) -> str:
    """The query minus filler words, prices and the slots already lifted out."""
    s = norm
    s = _MAX_PAT.sub(" ", s)
    s = _MIN_PAT.sub(" ", s)
    for key in ("city", "origin", "destination", "date", "quantity"):
        v = slots.get(key)
        if v:
            s = re.sub(re.escape(str(v)), " ", s, flags=re.I)
    words = [w for w in re.split(r"[\s،,;:؟?!]+", s) if w and w.lower() not in _FILLER]
    return " ".join(words).strip()


def query_text(frame: QueryFrame) -> str:
    """The free-text query a search tool receives: brand + product."""
    product = str(frame.slots.get("product") or "").strip()
    brand = str(frame.slots.get("brand") or "").strip()
    if brand and brand.lower() not in product.lower():
        return f"{brand} {product}".strip()
    return product or strip_known(frame.normalized, frame.slots) or frame.normalized


def merge_frames(previous: QueryFrame | None, new: QueryFrame) -> QueryFrame:
    """A follow-up inherits what it does not restate: 'in Isfahan' keeps the
    product and price of the search before it. Fresh values always win; the
    product replaces the old one only when the new frame names one."""
    if previous is None:
        return new
    merged = dict(previous.slots)
    for k, v in new.slots.items():
        merged[k] = v
    out = QueryFrame(
        text=new.text, normalized=new.normalized, entities=new.entities,
        domains=new.domains or previous.domains, intent=new.intent,
        slots=merged, source=new.source, assumptions=list(new.assumptions),
    )
    return out
