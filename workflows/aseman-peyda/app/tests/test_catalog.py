import json
from pathlib import Path

from peyda.catalog import Catalog
from peyda.frame import DOMAINS, build_frame


def test_the_shipped_catalog_is_consistent():
    cat = Catalog.load()
    assert len(cat.services) >= 50
    raw = json.loads((Path(__file__).resolve().parent.parent / "peyda" / "services.json").read_text(encoding="utf8"))
    pins = (Path(__file__).resolve().parent.parent / "requirements-services.txt").read_text().split()
    # iran-mcp packages are pinned; Peyda's own servers (a `module` of this app) are not packages
    assert {f"{s['package']}=={s['version']}" for s in raw["services"] if not s.get("module")} == set(pins)
    for s in raw["services"]:
        if s.get("module"):
            assert (Path(__file__).resolve().parent.parent / (s["module"].replace(".", "/") + ".py")).is_file(), s["id"]
    for s in cat.services.values():
        assert s.domains and set(s.domains) <= set(DOMAINS), s.id
        assert s.tools, s.id
    for dom, lead in cat.lead.items():
        assert dom in DOMAINS and all(i in cat.services for i in lead)
    for d in DOMAINS:
        assert any(d in s.domains for s in cat.services.values()), f"no service answers {d}"


def test_routing_leads_with_the_lead_services_and_honours_domains():
    cat = Catalog.load()
    f = build_frame("گوشی", {}, [{"name": "shopping", "score": 1}], "find")
    got = [s.id for s in cat.route(f, 4)]
    assert got[:3] == ["digikala", "torob", "emalls"] and len(got) == 4
    assert [s.id for s in cat.route(f, 3, exclude=["digikala"])][0] == "torob"
    assert all("food" in s.domains for s in cat.route(f, 6, domains=["food"]))


def test_a_route_tool_is_picked_by_the_words_of_the_request():
    cat = Catalog.load()
    mb = cat.services["mrbilit"]
    flight = build_frame("بلیط پرواز تهران مشهد", {}, [], "find")
    train = build_frame("بلیط قطار تهران مشهد", {}, [], "find")
    vague = build_frame("بلیط تهران مشهد", {}, [], "find")
    assert [t.name for t in mb.pick_tools(flight)] == ["mb_search_flights"]
    assert [t.name for t in mb.pick_tools(train)] == ["mb_search_trains"]
    assert [t.name for t in mb.pick_tools(vague)] == ["mb_search_flights"]  # the default
    assert cat.services["raja"].pick_tools(vague) == []  # a train-only server stays out of a vague request
    assert "raja" not in [s.id for s in cat.route(vague, 20, domains=["travel_tickets"])]
