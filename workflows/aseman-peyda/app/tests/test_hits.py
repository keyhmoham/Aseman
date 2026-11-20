import json

from peyda.hits import parse_hits


def test_a_product_list_in_json():
    text = json.dumps({"query": "x", "products": [
        {"title": "A", "price": "12,500,000", "url": "https://a", "seller": "S"}, {"name": "B", "price_toman": 9000}]})
    hits = parse_hits("shop", "t", text)
    assert [h.title for h in hits] == ["A", "B"]
    assert hits[0].price_toman == 12_500_000 and hits[0].url == "https://a" and hits[0].detail == "S"
    assert hits[1].price_toman == 9000


def test_a_bare_list_and_the_limit():
    assert len(parse_hits("s", "t", json.dumps([{"title": str(i)} for i in range(20)]), limit=5)) == 5


def test_an_answer_card_becomes_one_hit_of_facts():
    (h,) = parse_hits("rates", "t", json.dumps({"gold_18k_gram": 5400000, "dollar": 98000}))
    assert "gold_18k_gram: 5400000" in h.detail


def test_markdown_blocks_become_hits_with_link_and_price():
    hits = parse_hits("dict", "t", "## Word\nMeaning here\nSee https://d.example/x\n\n## Other\nPrice 1,200,000 Toman")
    assert [h.title for h in hits] == ["Word", "Other"]
    assert hits[0].url == "https://d.example/x" and hits[1].price_toman == 1_200_000


def test_rial_text_is_not_mistaken_for_toman():
    (h,) = parse_hits("s", "t", "Gold\n1,200,000 ریال")
    assert h.price_toman is None


def test_empty_and_unparseable():
    assert parse_hits("s", "t", "") == []
    assert parse_hits("s", "t", json.dumps({"products": []})) == []
    # an empty result list beside metadata is "nothing found", not an answer card
    assert parse_hits("s", "t", json.dumps({"query": "x", "results": [], "total": 0})) == []
