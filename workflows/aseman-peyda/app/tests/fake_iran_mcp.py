"""A stand-in for an iran-mcp server: a real MCP server over stdio, with tools
shaped like the real ones (a search, a route that needs codes and a date, a
place lookup, a geocoder, a location-bound search, a markdown answer, a
failing tool)."""
import json
from typing import Annotated, Literal

from pydantic import Field

try:  # MCP SDK 2.x renamed FastMCP
    from mcp.server.mcpserver import MCPServer as FastMCP
except ImportError:  # MCP SDK 1.x
    from mcp.server.fastmcp import FastMCP

mcp = FastMCP("fake-iran")

PRODUCTS = [
    {"title": "Samsung Galaxy A55", "price": 18_500_000, "url": "https://shop.example/a55", "seller": "Fake Shop"},
    {"title": "Samsung Galaxy A35", "price": 14_900_000, "url": "https://shop.example/a35", "seller": "Fake Shop"},
    {"title": "Samsung Galaxy S24", "price": 38_000_000, "url": "https://shop.example/s24", "seller": "Fake Shop"},
]


@mcp.tool()
def fk_search(query: str, max_price: int = 0, limit: int = 5) -> str:
    """Search products."""
    items = [p for p in PRODUCTS if (not max_price or p["price"] <= max_price) and query.split()[0].lower() in p["title"].lower()]
    return json.dumps({"query": query, "products": items[:limit]}, ensure_ascii=False)


@mcp.tool()
def fk_places(query: str) -> str:
    """Find a place code."""
    table = {"tehran": "THR", "تهران": "THR", "mashhad": "MHD", "مشهد": "MHD"}
    code = table.get(query.strip().lower())
    return json.dumps([{"code": code, "name": query}] if code else [])


@mcp.tool()
def fk_route(origin_code: str, destination_code: str, date: str, limit: int = 5) -> str:
    """Flights between two airport codes on a date."""
    return json.dumps({"flights": [{"title": f"{origin_code}→{destination_code} {date} 07:40", "price": 2_180_000, "airline": "Fake Air"}]})


@mcp.tool()
def fk_geo(query: str) -> str:
    """Address to coordinates."""
    return json.dumps({"results": [{"name": query, "lat": 35.7, "lon": 51.4}]})


@mcp.tool()
def fk_food(query: str, lat: float, lon: float) -> str:
    """Dishes near a point."""
    return json.dumps({"dishes": [{"name": f"{query} near {lat:.1f},{lon:.1f}", "price": 320_000, "restaurant": "Fake Kitchen"}]})


@mcp.tool()
def fk_text(query: str) -> str:
    """A markdown answer."""
    return f"## {query}\nMeaning: a thing.\nSee https://dict.example/{query}\n\n## Another\nPrice 1,200,000 Toman"


@mcp.tool()
def fk_boom(query: str) -> str:
    """Always fails."""
    raise RuntimeError("the site is down")


@mcp.tool()
def fk_prices() -> str:
    """No arguments: today's prices."""
    return json.dumps({"gold_18k_gram": 5_400_000, "dollar": 98_000})


@mcp.tool()
def fk_find(query: str, mode: Literal["flight", "train", "bus"], limit: int = 5) -> str:
    """A place lookup that cannot answer without its mode (like MrBilit's)."""
    codes = {"flight": {"tehran": "THR", "تهران": "THR", "mashhad": "MHD", "مشهد": "MHD"},
             "train": {"tehran": "stn-1", "تهران": "stn-1", "مشهد": "stn-2"}}
    code = codes.get(mode, {}).get(query.strip().lower())
    return json.dumps({"airports": [{"code": code, "city": query}] if code and mode == "flight" else [],
                       "cities": [{"code": (code or "XXX") + "ALL", "city": query}]})


CITIES = {"اصفهان": "isfahan", "شیراز": "shiraz", "تهران": "tehran"}
FIELDS = {"پوست": ("dermatology", "متخصص پوست و مو"), "قلب": ("cardiology", "متخصص قلب")}


@mcp.tool()
def fk_suggest(query: str) -> str:
    """Suggest cities and specialties together (like Paziresh24's), ids included."""
    cities = [{"name": n, "slug": slug, "id": 1700 + i} for i, (n, slug) in enumerate(CITIES.items()) if query.strip() in n]
    fields = [{"title": t, "slug": slug} for k, (slug, t) in FIELDS.items() if query.strip() in k]
    return json.dumps({"cities": cities, "specialties": fields, "queries": [query]}, ensure_ascii=False)


@mcp.tool()
def fk_doctors(
    city: Annotated[str, Field(pattern=r"^[a-z0-9-]+$", description="City slug, e.g. 'tehran'.")] = "ir",
    specialty: Annotated[str | None, Field(pattern=r"^[a-z0-9-]+$", description="Specialty slug from fk_suggest.")] = None,
    limit: int = 5,
) -> str:
    """Doctors by city and specialty slugs."""
    return json.dumps({"results": [{"name": f"Dr. {specialty or 'any'} in {city}", "url": "https://doc.example/1", "price_toman": 450_000}]})


@mcp.tool()
def fk_symbols(symbols: Annotated[list[str], Field(min_length=1, max_length=30, description="Symbol slugs.")]) -> str:
    """Prices for symbol slugs."""
    return json.dumps({"prices": [{"symbol": x, "price_toman": 1000 * (i + 1)} for i, x in enumerate(symbols)]})


if __name__ == "__main__":
    mcp.run()
