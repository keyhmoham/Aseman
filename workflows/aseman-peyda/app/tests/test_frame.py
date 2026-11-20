import datetime as dt

import pytest

from peyda.dates import jalali_to_gregorian, resolve_date
from peyda.frame import QueryFrame, build_frame, merge_frames, normalize_text, parse_amount_toman, query_text


@pytest.mark.parametrize("text,want", [
    ("20 million toman", 20_000_000),
    ("۲۰ میلیون تومان", 20_000_000),
    ("بیست میلیون", 20_000_000),
    ("1,500,000", 1_500_000),
    ("2.5 million", 2_500_000),
    ("۵۰۰ هزار تومان", 500_000),
    ("200 میلیون ریال", 20_000_000),
    ("nothing here", None),
])
def test_amounts(text, want):
    assert parse_amount_toman(text) == want


def test_normalize_folds_digits_and_letters():
    assert normalize_text("گوشي  ۱۲۳  كتاب") == "گوشی 123 کتاب"


def test_prices_come_from_the_sentence_not_the_span_label():
    f = build_frame("ارزان‌ترین گوشی سامسونگ زیر ۲۰ میلیون تومان",
                    {"product": [{"text": "گوشی", "confidence": 0.9}], "brand": [{"text": "سامسونگ", "confidence": 0.8}],
                     "price_max": [{"text": "۲۰ میلیون", "confidence": 0.7}]},
                    [{"name": "shopping", "score": 0.9}], "cheapest")
    assert f.slots["price_max_toman"] == 20_000_000
    assert "price_max" not in f.slots
    assert f.intent == "cheapest" and f.domain_names == ["shopping"]
    assert query_text(f) == "سامسونگ گوشی"


def test_min_and_max_and_a_reversed_range():
    f = build_frame("laptop above 30 million under 20 million", {}, [], "find")
    assert f.slots["price_max_toman"] == 20_000_000 and "price_min_toman" not in f.slots


def test_product_falls_back_to_what_is_left_after_the_slots():
    f = build_frame("cheapest pizza in Tehran", {"city": [{"text": "Tehran", "confidence": 0.9}]}, [], "find")
    assert f.slots["product"] == "pizza"


def test_follow_up_keeps_what_it_does_not_restate():
    first = build_frame("samsung phone under 20 million", {"brand": [{"text": "samsung", "confidence": 1}]}, [{"name": "shopping", "score": 1}], "find")
    again = build_frame("in Isfahan", {"city": [{"text": "Isfahan", "confidence": 1}]}, [], "find")
    merged = merge_frames(first, again)
    assert merged.slots["city"] == "Isfahan" and merged.slots["brand"] == "samsung" and merged.slots["price_max_toman"] == 20_000_000
    assert merged.domain_names == ["shopping"]


def test_frame_round_trips():
    f = build_frame("a b", {"city": [{"text": "x", "confidence": 1}]}, [{"name": "maps", "score": 1}], "find")
    assert QueryFrame.from_dict(f.to_dict()).to_dict() == f.to_dict()


TODAY = dt.date(2026, 11, 19)  # a Thursday


@pytest.mark.parametrize("text,want", [
    ("فردا", "2026-11-20"), ("tomorrow", "2026-11-20"), ("پس‌فردا", "2026-11-21"), ("today", "2026-11-19"),
    ("2026-12-01", "2026-12-01"), ("پنجشنبه", "2026-11-19"), ("پنجشنبه آینده", "2026-11-26"),
    ("Saturday", "2026-11-21"), ("some day", None), (None, None),
])
def test_dates(text, want):
    assert resolve_date(text, TODAY) == want


def test_jalali_dates():
    assert jalali_to_gregorian(1403, 1, 1) == dt.date(2024, 3, 20)
    assert resolve_date("۱۴۰۵/۰۹/۰۵", TODAY) == jalali_to_gregorian(1405, 9, 5).isoformat() == "2026-11-26"


class _FakeModel:
    ready = True

    def __init__(self, frame):
        self._frame = frame

    def extract(self, text):
        return self._frame

    def start(self):
        pass

    def status(self):
        return {"engine": "gliner2", "ready": True}


def _model_frame(text, domains, slots=None):
    from peyda.frame import build_frame
    ents = {k: [{"text": v, "confidence": 0.9}] for k, v in (slots or {}).items()}
    return build_frame(text, ents, [{"name": n, "score": s} for n, s in domains], "find")


def test_hybrid_drops_the_models_catch_all_shopping_on_a_service_query():
    from peyda.extractor import HybridExtractor
    text = "بلیط پرواز تهران به مشهد فردا"
    ex = HybridExtractor(_FakeModel(_model_frame(text, [("shopping", 0.57), ("travel_tickets", 0.47)], {"origin": "تهران", "destination": "مشهد"})))
    frame = ex.extract(text)
    assert frame.domain_names == ["travel_tickets"]
    assert any("shopping dropped" in a for a in frame.assumptions)


def test_hybrid_keeps_shopping_when_something_is_being_bought():
    from peyda.extractor import HybridExtractor
    text = "ارزان‌ترین گوشی سامسونگ زیر ۲۰ میلیون تومان"
    ex = HybridExtractor(_FakeModel(_model_frame(text, [("shopping", 0.65), ("prices", 0.37)], {"brand": "سامسونگ"})))
    assert "shopping" in ex.extract(text).domain_names


def test_hybrid_drops_the_models_catch_all_prices_on_a_food_query():
    from peyda.extractor import HybridExtractor
    text = "cheapest pizza near Saadat Abad"
    ex = HybridExtractor(_FakeModel(_model_frame(text, [("food", 0.68), ("prices", 0.31)], {"product": "pizza"})))
    assert ex.extract(text).domain_names == ["food"]


def test_hybrid_keeps_prices_when_the_query_asks_for_a_rate():
    from peyda.extractor import HybridExtractor
    text = "قیمت طلا و دلار امروز"
    ex = HybridExtractor(_FakeModel(_model_frame(text, [("prices", 0.8), ("shopping", 0.64)])))
    assert ex.extract(text).domain_names[0] == "prices"  # kept, and still first
