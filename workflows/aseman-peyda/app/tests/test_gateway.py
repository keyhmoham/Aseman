"""The gateway against a real MCP server over stdio (tests/fake_iran_mcp.py)."""
from peyda.frame import build_frame
from peyda.gateway import find_coords, pick_code


def frame(text, domain, **slots):
    f = build_frame(text, {}, [{"name": domain, "score": 1.0}], "find")
    f.slots.update(slots)
    return f


def by_id(result):
    return {r.id: r for r in result.runs}


async def test_a_search_asks_every_routed_service_and_reports_each_honestly(gateway):
    result = await gateway.search(frame("Samsung phone", "shopping", price_max_toman=20_000_000), max_services=4)
    runs = by_id(result)
    assert runs["shopa"].status == "ok" and [h.title for h in runs["shopa"].hits] == ["Samsung Galaxy A55", "Samsung Galaxy A35"]
    assert runs["shopa"].args["max_price"] == 20_000_000 and runs["shopa"].hits[0].price_toman == 18_500_000
    assert runs["broken"].status == "error" and ("site is down" in runs["broken"].reason or "fk_boom" in runs["broken"].reason)  # SDK 2.x masks the message
    assert runs["gone"].status == "skipped" and "not offered" in runs["gone"].reason
    assert [r.status for r in result.runs][:2] == ["ok", "ok"]  # answered first
    assert result.total == 4 and result.score > 0


async def test_servers_stay_warm_between_searches(gateway):
    await gateway.search(frame("Samsung", "shopping"), max_services=2)
    first = dict(gateway._conns)
    await gateway.search(frame("Samsung", "shopping"), max_services=2)
    assert gateway._conns["shopa"] is first["shopa"] and "shopa" in gateway.status()["warm"]


async def test_places_are_resolved_to_the_codes_a_route_tool_takes(gateway):
    f = frame("flight tehran to mashhad", "travel_tickets", origin="tehran", destination="mashhad", date="2026-12-01")
    (run,) = (await gateway.search(f)).runs
    assert run.status == "ok" and run.args == {"origin_code": "THR", "destination_code": "MHD", "date": "2026-12-01", "limit": 8}
    assert run.hits[0].title == "THR→MHD 2026-12-01 07:40"


async def test_a_missing_date_is_a_gap_for_the_agent_not_a_guess(gateway):
    f = frame("flight tehran to mashhad", "travel_tickets", origin="tehran", destination="mashhad")
    result = await gateway.search(f)
    (run,) = result.runs
    assert run.status == "skipped" and run.missing == ["date"] and result.gaps == [{"service": "air", "missing": ["date"]}]


async def test_a_route_without_both_ends_is_skipped_with_what_it_needs(gateway):
    (run,) = (await gateway.search(frame("flight to mashhad", "travel_tickets", destination="mashhad"))).runs
    assert run.status == "skipped" and run.missing == ["origin"]


async def test_location_bound_tools_get_coordinates_and_the_assumption_is_recorded(gateway):
    f = frame("pizza", "food")
    (run,) = (await gateway.search(f)).runs
    assert run.status == "ok" and run.hits[0].title == "pizza near 35.7,51.4"
    assert any("assumed" in a for a in f.assumptions)


async def test_tools_without_arguments_and_markdown_answers(gateway):
    (rates,) = (await gateway.search(frame("gold price", "prices"))).runs
    assert rates.status == "ok" and "gold_18k_gram: 5400000" in rates.hits[0].detail
    (word,) = (await gateway.search(frame("meaning of x", "reference", product="x"))).runs
    assert word.hits[0].title == "x" and word.hits[0].url == "https://dict.example/x"


async def test_exclude_and_only(gateway):
    f = frame("Samsung", "shopping")
    assert "shopa" not in by_id(await gateway.search(f, exclude=["shopa"]))
    assert list(by_id(await gateway.search(f, only=["shopb"]))) == ["shopb"]


async def test_a_dead_server_is_restarted_on_the_next_search(gateway):
    f = frame("Samsung", "shopping")
    await gateway.search(f, only=["shopa"])
    conn = gateway._conns["shopa"]
    await conn.close()
    assert not conn.alive
    (run,) = (await gateway.search(f, only=["shopa"])).runs
    assert run.status == "ok" and gateway._conns["shopa"] is not conn


def test_pick_code_and_find_coords():
    assert pick_code('[{"code": "THR", "name": "Tehran"}]') == "THR"
    assert pick_code('{"stations": [{"id": 12, "name": "x"}]}') == "12"
    assert pick_code("Airport THR is the code") == "THR"
    assert find_coords('{"results": [{"point": {"latitude": 35.7, "longitude": 51.4}}]}') == (35.7, 51.4)
    assert find_coords("lat: 35.5 lon: 51.1") == (35.5, 51.1)
    assert find_coords("nothing") is None


async def test_a_lookup_that_needs_its_mode_gets_it_from_the_route(gateway):
    f = frame("flight tehran to mashhad", "stays", origin="tehran", destination="mashhad", date="2026-12-01")
    (run,) = (await gateway.search(f, only=["lookup_air"])).runs
    assert run.status == "ok" and run.args["origin_code"] == "THR", run.reason  # the airport, not the city's "THRALL"


async def test_doctor_searches_get_the_slugs_the_site_itself_suggests(gateway):
    """City and specialty are Persian in the query; the tool takes ASCII slugs (and a numeric id sits beside the slug)."""
    f = frame("دکتر پوست در اصفهان", "health", city="اصفهان", product="دکتر پوست")
    (run,) = (await gateway.search(f, only=["doctors"])).runs
    assert run.status == "ok", run.reason
    assert run.args["city"] == "isfahan" and run.args["specialty"] == "dermatology"
    assert run.hits[0].price_toman == 450_000


async def test_an_unresolvable_slug_is_left_out_not_sent_as_persian_text(gateway):
    f = frame("دکتر در ناکجاآباد", "health", city="ناکجاآباد")
    (run,) = (await gateway.search(f, only=["doctors"])).runs
    assert run.status == "ok" and "city" not in run.args  # the tool's own default (the whole country) applies


async def test_a_price_feed_gets_the_symbols_the_words_name(gateway):
    (run,) = (await gateway.search(frame("قیمت دلار و طلا", "markets"), only=["feed"])).runs
    assert run.status == "ok" and run.args == {"symbols": ["usd_rl", "gold18"]}
    f = frame("قیمت امروز", "markets")
    (run,) = (await gateway.search(f, only=["feed"])).runs
    assert run.args == {"symbols": ["usd_rl", "gold18"]} and any("main rates" in a for a in f.assumptions)


def test_pick_code_prefers_the_slug_when_asked_and_reads_the_named_list():
    cities = '{"cities": [{"id": 2200, "slug": "tehran", "name": "x"}], "specialties": [{"slug": "dermatology"}]}'
    assert pick_code(cities) == "2200"
    assert pick_code(cities, want="slug") == "tehran"
    assert pick_code(cities, want="slug", lists=("specialties",)) == "dermatology"
    assert pick_code('{"specialties": [{"slug": "d"}], "cities": []}', want="slug", lists=("cities",), avoid=("specialties",)) is None
