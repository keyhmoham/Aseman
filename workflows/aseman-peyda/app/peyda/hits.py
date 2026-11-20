"""Whatever a site's tool answered → a list of comparable result cards.

iran-mcp tools answer with MCP text content: most often compact JSON, sometimes
markdown. A `Hit` is the least that a results page and the agent both need:
a title, where to go, a price in Toman when there is one, and a line of detail.
Nothing here knows a particular server; it reads shapes, so a server that
changes its fields degrades to plain text hits instead of failing.
"""
from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from typing import Any

from .frame import normalize_text

TITLE_KEYS = ("title", "name", "fa_title", "title_fa", "name_fa", "product_name", "label", "headline", "text", "symbol", "fa_name")
URL_KEYS = ("url", "link", "web_url", "permalink", "href", "page_url", "share_url")
PRICE_KEYS = ("price_toman", "price", "min_price", "cheapest", "cheapest_price", "amount", "cost", "fare", "price_from", "final_price", "selling_price")
IMAGE_KEYS = ("image", "image_url", "thumbnail", "img", "cover", "photo", "picture")
DETAIL_KEYS = ("subtitle", "description", "summary", "brand", "vendor", "seller", "shop", "store", "city", "address", "category", "district", "company", "date", "time", "rating")
LIST_KEYS = ("items", "results", "products", "data", "ads", "offers", "listings", "hotels", "flights", "trains", "buses", "doctors", "rows", "list", "records", "courses", "books", "jobs", "projects", "articles", "posts", "places", "apps", "dishes", "vendors", "stays", "rooms")

_URL = re.compile(r"https?://[^\s)>\]\"']+")
_PRICE_TEXT = re.compile(r"(\d[\d,]{3,})\s*(?:تومان|toman|ریال|rial)", re.I)


@dataclass
class Hit:
    service: str
    tool: str
    title: str
    url: str = ""
    price_toman: int | None = None
    detail: str = ""
    image: str = ""
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        if not d["extra"]:
            d.pop("extra")
        return {k: v for k, v in d.items() if v not in ("", None)}


def attr(obj: Any, *names: str) -> Any:
    """The first attribute present: MCP SDK 1.x names are camelCase, 2.x snake_case."""
    for n in names:
        v = getattr(obj, n, None)
        if v is not None:
            return v
    return None


def result_text(result: Any) -> str:
    """The text of an MCP CallToolResult (or a plain string/dict, for tests)."""
    if isinstance(result, str):
        return result
    if isinstance(result, (dict, list)):
        return json.dumps(result, ensure_ascii=False)
    structured = attr(result, "structuredContent", "structured_content")
    parts = [getattr(c, "text", "") for c in (getattr(result, "content", None) or []) if getattr(c, "type", "") == "text"]
    text = "\n".join(p for p in parts if p).strip()
    if text:
        return text
    return json.dumps(structured, ensure_ascii=False) if structured else ""


def _parse_json(text: str) -> Any:
    t = text.strip()
    if not t or t[0] not in "[{":
        return None
    try:
        return json.loads(t)
    except ValueError:
        return None


def _to_toman(v: Any) -> int | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v) if v > 0 else None
    if isinstance(v, str):
        digits = normalize_text(v).replace(",", "")
        m = re.fullmatch(r"\d+(?:\.\d+)?", digits)
        return int(float(digits)) if m and float(digits) > 0 else None
    return None


def _first(d: dict[str, Any], keys: tuple[str, ...]) -> Any:
    for k in keys:
        if k in d and d[k] not in (None, "", [], {}):
            return d[k]
    return None


def _record_list(data: Any) -> list[dict[str, Any]] | None:
    """The list of records in a JSON answer: the answer itself, a well-known
    key, or the longest list of objects one level down."""
    if isinstance(data, list):
        recs = [x for x in data if isinstance(x, dict)]
        return recs or None
    if not isinstance(data, dict):
        return None
    for k in LIST_KEYS:
        v = data.get(k)
        if isinstance(v, list) and v and isinstance(v[0], dict):
            return [x for x in v if isinstance(x, dict)]
    best: list[dict[str, Any]] = []
    for v in data.values():
        if isinstance(v, list) and v and isinstance(v[0], dict) and len(v) > len(best):
            best = [x for x in v if isinstance(x, dict)]
        elif isinstance(v, dict):
            inner = _record_list(v)
            if inner and len(inner) > len(best):
                best = inner
    return best or None


def _record_to_hit(service: str, tool: str, rec: dict[str, Any]) -> Hit | None:
    title = _first(rec, TITLE_KEYS)
    if isinstance(title, (dict, list)):
        title = json.dumps(title, ensure_ascii=False)[:120]
    url = _first(rec, URL_KEYS)
    price = None
    for k in PRICE_KEYS:
        price = _to_toman(rec.get(k))
        if price:
            break
    if not title and not url:
        # a record with neither: describe it by its first scalar fields
        scalars = [f"{k}: {v}" for k, v in rec.items() if isinstance(v, (str, int, float)) and v != ""][:4]
        if not scalars:
            return None
        title = "; ".join(scalars)
    detail_bits: list[str] = []
    for k in DETAIL_KEYS:
        v = rec.get(k)
        if isinstance(v, (str, int, float)) and not isinstance(v, bool) and str(v).strip() and str(v) != str(title):
            detail_bits.append(f"{k}: {v}" if k in ("rating", "date", "time") else str(v))
        if len(detail_bits) >= 3:
            break
    image = _first(rec, IMAGE_KEYS)
    return Hit(
        service=service, tool=tool, title=str(title or url)[:200],
        url=str(url) if isinstance(url, str) else "", price_toman=price,
        detail=" · ".join(detail_bits)[:240], image=str(image) if isinstance(image, str) else "",
    )


def _blocks(text: str) -> list[str]:
    blocks = [b.strip() for b in re.split(r"\n\s*\n|\n(?=#{1,4} )|\n(?=[-*] \*\*)", text) if b.strip()]
    return blocks or [text.strip()]


def parse_hits(service: str, tool: str, result: Any, limit: int = 8) -> list[Hit]:
    text = result_text(result)
    if not text:
        return []
    data = _parse_json(text)
    if data is not None:
        recs = _record_list(data)
        if recs:
            hits = [h for h in (_record_to_hit(service, tool, r) for r in recs) if h]
            return hits[:limit]
        if isinstance(data, dict) and any(isinstance(v, list) for v in data.values()):
            return []  # a list of results that is empty: nothing was found
        if isinstance(data, dict):
            # an answer card: a handful of facts (a price table, today's date)
            facts = [f"{k}: {v}" for k, v in data.items() if isinstance(v, (str, int, float)) and not isinstance(v, bool)][:8]
            if facts:
                return [Hit(service=service, tool=tool, title=_first(data, TITLE_KEYS) and str(_first(data, TITLE_KEYS))[:120] or tool,
                            detail=" · ".join(facts)[:400])]
        return []
    hits: list[Hit] = []
    for block in _blocks(text)[: limit]:
        lines = [ln.strip() for ln in block.splitlines() if ln.strip()]
        if not lines:
            continue
        title = re.sub(r"^[#>*\-\s]+|\*\*", "", lines[0]).strip()[:200]
        link = _URL.search(block)
        price = _PRICE_TEXT.search(block)
        in_rial = bool(price) and ("ریال" in price.group(0) or "rial" in price.group(0).lower())
        hits.append(Hit(
            service=service, tool=tool, title=title or tool, url=link.group(0) if link else "",
            price_toman=int(price.group(1).replace(",", "")) if price and not in_rial else None,
            detail=" ".join(lines[1:])[:240],
        ))
    return hits
