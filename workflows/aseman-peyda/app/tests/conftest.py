import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from mcp import StdioServerParameters  # noqa: E402

from peyda.catalog import Catalog, Service, ToolRoute  # noqa: E402
from peyda.extractor import HeuristicExtractor  # noqa: E402
from peyda.gateway import Gateway  # noqa: E402

FAKE = str(Path(__file__).resolve().parent / "fake_iran_mcp.py")


def make_catalog() -> Catalog:
    svc = lambda i, domains, tools, **kw: Service(id=i, package="fake", title=i.title(), site=f"https://{i}.example", domains=domains, tools=tools, **kw)  # noqa: E731
    return Catalog(
        [
            svc("shopa", ["shopping"], [ToolRoute("fk_search")]),
            svc("shopb", ["shopping"], [ToolRoute("fk_search")]),
            svc("air", ["travel_tickets"], [ToolRoute("fk_route", needs=["origin", "destination"], kw=["پرواز", "flight"], default=True)], resolve="fk_places"),
            svc("kitchen", ["food"], [ToolRoute("fk_food")], geocode="fk_geo"),
            svc("dict", ["reference"], [ToolRoute("fk_text")]),
            svc("broken", ["shopping"], [ToolRoute("fk_boom")]),
            svc("gone", ["shopping"], [ToolRoute("fk_not_there")]),
            svc("rates", ["prices"], [ToolRoute("fk_prices", args={})]),
            svc("lookup_air", ["stays"], [ToolRoute("fk_route", needs=["origin", "destination"], resolve_args={"mode": "flight"})], resolve="fk_find"),
            svc("doctors", ["health"], [ToolRoute("fk_doctors")], resolve="fk_suggest", resolve_specialty="fk_suggest"),
            svc("feed", ["markets"], [ToolRoute("fk_symbols", symbols={"دلار": "usd_rl", "طلا": "gold18", "gold": "gold18"}, default_symbols=["usd_rl", "gold18"])]),
        ],
        {"shopping": ["shopa", "shopb"]},
    )


@pytest.fixture
def catalog() -> Catalog:
    return make_catalog()


@pytest.fixture
async def gateway(catalog):
    gw = Gateway(
        catalog,
        lambda service: StdioServerParameters(command=sys.executable, args=[FAKE]),
        tool_timeout=20, startup_timeout=60, idle_seconds=60, default_city="تهران",
    )
    yield gw
    await gw.close()


@pytest.fixture
def lexicon():
    return HeuristicExtractor()
