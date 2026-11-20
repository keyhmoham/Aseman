"""A frame + a tool's JSON Schema → the tool's arguments.

iran-mcp has ~1,150 tools from 96 independent servers, and their parameter
names differ (`query`, `q`, `keyword`, `product_name`…). Rather than hard-code
each, the gateway reads the `inputSchema` the server itself publishes and fills
each property from the slot whose name it matches. A required property no slot
can fill is reported back (`missing`), never invented: the agent turns it into
a question, or a better query.
"""
from __future__ import annotations

import datetime as dt
import re
from typing import Any

from .dates import resolve_date
from .frame import QueryFrame, query_text

# normalised parameter name (lower-case, letters and digits only) → slot
_NAMES: dict[str, set[str]] = {
    "query": {"query", "q", "keyword", "keywords", "search", "searchterm", "searchquery", "term", "text", "name",
              "title", "product", "productname", "phrase", "dish", "symbol", "word", "topic", "searchtext", "kw"},
    "city": {"city", "cityname", "town", "province", "region", "cityslug", "citycode", "cityid"},
    "origin": {"origin", "from", "fromcity", "source", "departure", "origincity", "src", "fromstation",
               "fromairport", "originairport", "origincode", "fromcode", "fromid", "depart", "originid", "sourcecity"},
    "destination": {"destination", "to", "tocity", "dest", "arrival", "destinationcity", "tostation",
                    "toairport", "destinationcode", "toid", "dst", "destcode", "destinationid", "targetcity"},
    "date": {"date", "departuredate", "departdate", "traveldate", "day", "checkin", "startdate", "datefrom",
             "flightdate", "tripdate", "when"},
    "price_max": {"maxprice", "pricemax", "budget", "maxbudget", "priceto", "maximumprice", "pricelte",
                  "maxpricetoman", "maxtoman", "pricemaxtoman"},
    "price_min": {"minprice", "pricemin", "pricefrom", "minimumprice", "pricegte", "mintoman", "priceminttoman"},
    "specialty": {"specialty", "speciality", "expertise", "field", "specialization"},
    "person": {"doctorname", "person", "author", "actor", "fullname"},
    "limit": {"limit", "count", "perpage", "pagesize", "n", "top", "size", "maxresults", "topn", "numresults", "limitperpage"},
    "lat": {"lat", "latitude"},
    "lon": {"lon", "lng", "longitude", "long"},
    "address": {"address", "addr", "location", "place", "near", "point"},
}
_LOOKUP = {n: slot for slot, names in _NAMES.items() for n in names}
_CODEISH = ("code", "iata", "slug", "station", "id")


def _norm(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


def slot_of(param: str) -> str | None:
    return _LOOKUP.get(_norm(param))


def _coerce(value: Any, spec: dict[str, Any]) -> Any:
    """Shapes a value to the property's declared type; None when it cannot."""
    kind = spec.get("type")
    if isinstance(kind, list):  # ["string", "null"]
        kind = next((k for k in kind if k != "null"), None)
    if "anyOf" in spec and not kind:
        kind = next((o.get("type") for o in spec["anyOf"] if o.get("type") not in (None, "null")), None)
    enum = spec.get("enum")
    if enum:
        for e in enum:
            if str(e).lower() == str(value).lower():
                return e
        return None
    try:
        if kind in ("integer", "number"):
            n = int(float(value)) if kind == "integer" else float(value)
            if "maximum" in spec:
                n = min(n, spec["maximum"])
            if "minimum" in spec:
                n = max(n, spec["minimum"])
            return n
        if kind == "array":
            return [value]
        if kind == "boolean":
            return None
    except (TypeError, ValueError):
        return None
    return str(value)


def _variants(spec: dict[str, Any]) -> list[dict[str, Any]]:
    opts = [o for o in spec.get("anyOf", []) if o.get("type") != "null"]
    return opts or [spec]


def accepts(value: Any, spec: dict[str, Any]) -> bool:
    """Whether a string value meets the property's own limits (pattern, length).
    A server checks these before it runs; a value that fails would only come back
    as a rejected call, so it is not sent."""
    if not isinstance(value, str):
        return True
    for v in _variants(spec):
        if v.get("type") not in (None, "string"):
            continue
        pat = v.get("pattern")
        if pat:
            try:
                if not re.search(pat, value):
                    continue
            except re.error:
                pass
        if len(value) < v.get("minLength", 0) or len(value) > v.get("maxLength", 10**9):
            continue
        return True
    return False


def build_args(
    schema: dict[str, Any],
    frame: QueryFrame,
    *,
    limit: int = 8,
    resolved: dict[str, str] | None = None,
    coords: tuple[float, float] | None = None,
    address: str = "",
    today: dt.date | None = None,
) -> tuple[dict[str, Any], list[str]]:
    """Returns (arguments, missing). `missing` names what a required property
    needed in the frame's own words ('date', 'origin', …) or the parameter."""
    props: dict[str, Any] = (schema or {}).get("properties") or {}
    required = set((schema or {}).get("required") or [])
    resolved = resolved or {}
    slots = frame.slots
    values: dict[str, Any] = {
        "query": query_text(frame),
        "city": slots.get("city") or slots.get("origin"),
        "origin": slots.get("origin"), "destination": slots.get("destination"),
        "date": resolve_date(slots.get("date"), today),
        "price_max": slots.get("price_max_toman"), "price_min": slots.get("price_min_toman"),
        # a doctor's field is what the model often files under "product" ("دکتر پوست")
        "specialty": slots.get("specialty") or (slots.get("product") if "health" in frame.domain_names else None),
        "person": slots.get("person"),
        "limit": limit,
        "lat": coords[0] if coords else None, "lon": coords[1] if coords else None,
        "address": address or slots.get("city") or None,
    }
    args: dict[str, Any] = {}
    missing: list[str] = []
    unmatched_required: list[str] = []
    for name, spec in props.items():
        slot = slot_of(name)
        if slot is None:
            if name in required and "default" not in spec:
                unmatched_required.append(name)
            continue
        value = values.get(slot)
        if slot in ("origin", "destination", "city", "specialty") and slot in resolved and (
            any(h in _norm(name) for h in _CODEISH) or any(h in str(spec.get("description", "")).lower() for h in ("code", "iata", "slug", "id of"))
        ):
            value = resolved[slot]
        if value in (None, "", []):
            if name in required and "default" not in spec:
                missing.append(slot if slot in ("date", "origin", "destination", "city") else name)
            continue
        shaped = _coerce(value, spec)
        if shaped is not None and not accepts(shaped, spec):
            shaped = None  # e.g. Persian text for a parameter that takes an ASCII slug
        if shaped is None:
            if name in required and "default" not in spec:
                missing.append(name)
            continue
        args[name] = shaped
    # A tool with one free-text requirement we could not name takes the query.
    free = [n for n in unmatched_required if _coerce("x", props[n]) == "x"]
    if len(unmatched_required) == 1 and free and not any(slot_of(k) == "query" for k in args):
        text = values["query"]
        if text and accepts(text, props[free[0]]):
            args[free[0]] = text
            unmatched_required = []
    missing.extend(unmatched_required)
    return args, sorted(set(missing))
