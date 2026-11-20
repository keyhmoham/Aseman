from peyda.args import build_args
from peyda.frame import build_frame


def frame(text="سامسونگ گوشی", **slots):
    f = build_frame(text, {}, [], "find")
    f.slots.update(slots)
    return f


SEARCH = {"properties": {"query": {"type": "string"}, "max_price": {"type": "integer"}, "limit": {"type": "integer", "maximum": 5}}, "required": ["query"]}


def test_fills_by_name_and_clamps_to_the_schema():
    args, missing = build_args(SEARCH, frame(price_max_toman=20_000_000), limit=9)
    assert args == {"query": "سامسونگ گوشی", "max_price": 20_000_000, "limit": 5} and missing == []


def test_a_required_slot_nothing_can_fill_is_reported_not_invented():
    schema = {"properties": {"origin": {"type": "string"}, "destination": {"type": "string"}, "date": {"type": "string"}}, "required": ["origin", "destination", "date"]}
    args, missing = build_args(schema, frame(origin="tehran", destination="mashhad"))
    assert missing == ["date"] and args["origin"] == "tehran"


def test_codes_are_used_where_the_parameter_asks_for_a_code():
    schema = {"properties": {"origin_code": {"type": "string"}, "to": {"type": "string", "description": "city name"}}, "required": ["origin_code", "to"]}
    args, _ = build_args(schema, frame(origin="tehran", destination="mashhad"), resolved={"origin": "THR", "destination": "MHD"})
    assert args == {"origin_code": "THR", "to": "mashhad"}


def test_dates_become_iso():
    import datetime as dt
    schema = {"properties": {"date": {"type": "string"}}, "required": ["date"]}
    args, _ = build_args(schema, frame(date="فردا"), today=dt.date(2026, 11, 19))
    assert args["date"] == "2026-11-20"


def test_enum_must_match_and_a_lone_free_text_requirement_takes_the_query():
    schema = {"properties": {"sort": {"type": "string", "enum": ["price", "rating"]}, "needle": {"type": "string"}}, "required": ["needle"]}
    args, missing = build_args(schema, frame())
    assert args == {"needle": "سامسونگ گوشی"} and missing == []


def test_defaults_are_left_to_the_server():
    schema = {"properties": {"city": {"type": "string", "default": "tehran"}}, "required": ["city"]}
    args, missing = build_args(schema, frame())
    assert args == {} and missing == []


def test_coordinates():
    schema = {"properties": {"query": {"type": "string"}, "lat": {"type": "number"}, "lon": {"type": "number"}}, "required": ["query", "lat", "lon"]}
    args, missing = build_args(schema, frame("pizza"), coords=(35.7, 51.4))
    assert args["lat"] == 35.7 and args["lon"] == 51.4 and not missing


SLUGS = {"properties": {
    "city": {"type": "string", "pattern": "^[a-z0-9-]+$", "maxLength": 60, "default": "ir", "description": "City slug"},
    "specialty": {"anyOf": [{"type": "string", "pattern": "^[a-z0-9-]+$"}, {"type": "null"}], "default": None, "description": "Specialty slug"}}}


def test_a_value_that_breaks_the_properties_pattern_is_not_sent():
    args, missing = build_args(SLUGS, frame(city="اصفهان"))
    assert args == {} and missing == []  # Persian text for an ASCII slug would only come back rejected


def test_a_resolved_slug_is_sent_and_a_health_query_reads_the_field_from_the_product():
    health = build_frame("دکتر پوست", {}, [{"name": "health", "score": 1.0}], "find")
    health.slots.update(city="اصفهان", product="دکتر پوست")
    args, _ = build_args(SLUGS, health, resolved={"city": "isfahan", "specialty": "dermatology"})
    assert args == {"city": "isfahan", "specialty": "dermatology"}


def test_a_required_value_that_fails_its_pattern_is_a_gap():
    schema = {"properties": {"code": {"type": "string", "pattern": "^[A-Z]{3}$"}}, "required": ["code"]}
    args, missing = build_args(schema, frame(city="x"), resolved={})
    assert args == {} and missing == ["code"]  # the query is not a three-letter code, so it is a gap
