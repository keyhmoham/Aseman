#!/usr/bin/env python3
"""Builds peyda/services.json and requirements-services.txt from iran-mcp's own
servers.json, so package names, pinned versions, proxy variables and tool names
come from the catalog the servers publish, not from memory.

    python3 scripts/gen_services.py /path/to/iran-mcp/servers.json

Only the routing (which domains a server answers, which of its tools is the
search entry point, what that tool needs) is written here. Re-run it when
iran-mcp releases; it fails loudly when a tool this file names has been renamed.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

FLIGHT = ["پرواز", "هواپیما", "flight", "fly", "airfare"]
TRAIN = ["قطار", "train", "rail"]
BUS = ["اتوبوس", "bus"]
RT = ["origin", "destination"]  # a route needs both ends

# id → (server package, domains, [search tools], extra)
# A tool is "name" or {"name":…, "needs":[slots that must be present], "args":{static arguments}}
# TGJU's price feed takes symbol slugs: the words people use for them.
TGJU_SYMBOLS = {"دلار": "price_dollar_rl", "dollar": "price_dollar_rl", "usd": "price_dollar_rl",
                "یورو": "price_eur", "euro": "price_eur", "پوند": "price_gbp", "pound": "price_gbp",
                "طلا": "geram18", "طلای": "geram18", "gold": "geram18",
                "سکه": "sekee", "coin": "sekee", "نیم سکه": "nim", "ربع سکه": "rob", "انس": "ons", "ounce": "ons"}
TGJU_DEFAULT = ["price_dollar_rl", "price_eur", "geram18", "sekee"]

ROUTES: dict[str, tuple[str, list[str], list, dict]] = {
    # shopping
    "digikala": ("digikala-mcp", ["shopping"], ["dk_find_cheapest"], {}),
    "torob": ("torob-mcp", ["shopping"], ["tb_cheapest"], {}),
    "emalls": ("emalls-ir-mcp", ["shopping"], ["em_search"], {}),
    "snappshop": ("snappshop-mcp", ["shopping"], ["ss_search"], {}),
    "technolife": ("technolife-mcp", ["shopping"], ["tl_find_cheapest"], {}),
    "basalam": ("basalam-mcp", ["shopping"], ["bs_find_cheapest"], {}),
    "mobile": ("mobile-ir-mcp", ["shopping"], ["mi_search"], {"hint": "phones"}),
    "zoomit": ("zoomit-mcp", ["shopping", "news"], ["zm_search"], {"hint": "phones, laptops, GPUs"}),
    # classifieds, homes, cars
    "divar": ("divar-mcp", ["classifieds", "real_estate", "cars"], ["dv_search"], {}),
    "sheypoor": ("sheypoor-mcp", ["classifieds", "real_estate", "cars"], ["sp_search"], {}),
    "kilid": ("kilid-mcp", ["real_estate"], ["kl_search_listings"], {"resolve": "kl_cities"}),
    "bama": ("bama-ir-mcp", ["cars"], ["ba_search"], {}),
    "khodro45": ("khodro45-mcp", ["cars"], ["k45_cars"], {}),
    # food
    "snapp": ("snapp-mcp", ["food"], ["food_find_cheapest"], {"geocode": "find_location"}),
    "tapsifood": ("tapsifood-mcp", ["food"], ["tf_search_dishes"], {"geocode": "tf_find_location"}),
    "okala": ("okala-mcp", ["food", "shopping"], ["ok_search"], {"geocode": "ok_locate"}),
    # travel
    "mrbilit": ("mrbilit-mcp", ["travel_tickets"], [
        {"name": "mb_search_flights", "needs": RT, "kw": FLIGHT, "default": True, "resolve_args": {"mode": "flight"}},
        {"name": "mb_search_trains", "needs": RT, "kw": TRAIN, "resolve_args": {"mode": "train"}},
        {"name": "mb_search_buses", "needs": RT, "kw": BUS, "resolve_args": {"mode": "bus"}}], {"resolve": "mb_find_place"}),
    "flytoday": ("flytoday-mcp", ["travel_tickets"], [{"name": "ft_search_flights", "needs": RT, "kw": FLIGHT, "default": True}], {"resolve": "ft_find_airport"}),
    "alibaba": ("alibaba-ir-mcp", ["travel_tickets"], [
        {"name": "al_flights_cheapest", "needs": RT, "kw": FLIGHT, "default": True},
        {"name": "al_trains_cheapest", "needs": RT, "kw": TRAIN}], {"resolve": "al_cities"}),
    "raja": ("raja-mcp", ["travel_tickets"], [{"name": "rj_search_trains", "needs": RT, "kw": TRAIN}], {"resolve": "rj_stations"}),
    "bus": ("iran-bus-mcp", ["travel_tickets"], [{"name": "bus_cheapest", "needs": RT, "kw": BUS}], {"resolve": "bus_cities"}),
    "snapptrip": ("snapptrip-mcp", ["stays"], ["st_hotel_search"], {"resolve": "st_hotel_places"}),
    "jabama": ("jabama-mcp", ["stays"], ["jb_search_stays"], {}),
    "otaghak": ("otaghak-mcp", ["stays"], ["ot_search_rooms"], {}),
    "eghamat24": ("eghamat24-mcp", ["stays"], ["eg_search"], {}),
    # maps
    "neshan": ("neshan-mcp", ["maps"], ["ns_search"], {}),
    "balad": ("balad-mcp", ["maps"], ["bl_search"], {}),
    # health
    "paziresh24": ("paziresh24-mcp", ["health"], ["pz_search_doctors"], {"resolve": "pz_suggest", "resolve_specialty": "pz_suggest"}),
    "doctoreto": ("doctoreto-mcp", ["health"], ["dt_search_doctors"], {"resolve": "dt_cities", "resolve_specialty": "dt_suggest"}),
    "exiryab": ("exiryab-mcp", ["health"], ["ey_search_doctors"], {}),
    "darukade": ("darukade-mcp", ["health", "shopping"], ["dr_search"], {}),
    # books, learning, work
    "taaghche": ("taaghche-mcp", ["books"], ["tg_search"], {}),
    "fidibo": ("fidibo-mcp", ["books"], ["fd_search"], {}),
    "iranketab": ("iranketab-mcp", ["books"], ["ik_search"], {}),
    "30book": ("30book-mcp", ["books"], ["sb_search"], {}),
    "maktabkhooneh": ("maktabkhooneh-mcp", ["courses"], ["mkh_search"], {}),
    "faradars": ("faradars-mcp", ["courses"], ["fr_search_courses"], {}),
    "iran_jobs": ("iran-jobs-mcp", ["jobs"], ["job_search"], {}),
    "ponisha": ("ponisha-mcp", ["freelance"], ["pn_search_projects"], {}),
    "karlancer": ("karlancer-mcp", ["freelance"], ["kl_projects"], {}),
    # software
    "iran_apps": ("iran-apps-mcp", ["software"], ["ap_search"], {}),
    "iran_downloads": ("iran-downloads-mcp", ["software"], ["dl_search"], {}),
    # markets
    "tgju": ("tgju-mcp", ["prices"], [{"name": "tj_get_prices", "symbols": TGJU_SYMBOLS, "default_symbols": TGJU_DEFAULT}], {}),
    "iran_gold": ("iran-gold-mcp", ["prices"], [{"name": "gold_prices", "args": {}}], {}),
    "iran_crypto": ("iran-crypto-mcp", ["prices"], ["ic_compare_price"], {}),
    "tsetmc": ("tsetmc-mcp", ["stocks"], ["ts_search_symbols"], {}),
    "codal": ("codal-mcp", ["stocks"], ["cd_search_letters"], {}),
    "fipiran": ("fipiran-mcp", ["stocks"], ["fp_search_funds"], {}),
    # news, media, reference
    "iran_news": ("iran-news-mcp", ["news"], ["nw_search"], {}),
    "iran_vod": ("iran-vod-mcp", ["media"], ["vod_search"], {}),
    "aparat": ("aparat-mcp", ["media"], ["apr_search"], {}),
    "cinematicket": ("cinematicket-mcp", ["media"], [{"name": "ct_now_showing", "args": {}}], {}),
    "tiwall": ("tiwall-mcp", ["media"], ["tw_search"], {}),
    "weather": ("iran-weather-mcp", ["weather_time"], ["wx_cities"], {}),
    "time_ir": ("time-ir-mcp", ["weather_time"], [{"name": "ti_today", "args": {}}], {}),
    "dictionary": ("iran-dictionary-mcp", ["reference"], ["dic_lookup"], {}),
    "wikipedia": ("persian-wikipedia-mcp", ["reference"], ["wiki_search"], {}),
    "virgool": ("virgool-mcp", ["reference", "news"], ["vg_search"], {}),
    "qavanin": ("qavanin-mcp", ["law"], ["qv_search"], {}),
    "rrk": ("rrk-mcp", ["law"], ["rk_search_laws"], {}),
    "varzesh3": ("varzesh3-mcp", ["sports"], [{"name": "v3_scores", "args": {}}], {}),
}

# Peyda's own MCP servers, in front of engines that are not iran-mcp servers. They are
# modules of this app (`python -m <module>`), not packages, so they are not pinned here.
LOCAL = [
    {"id": "gmaps", "package": "peyda-gmaps", "module": "peyda.gmaps_mcp", "version": "kit-c3e63f1",
     "title": "Google Maps", "site": "https://www.google.com/maps",
     "domains": ["maps", "food", "health", "stays"], "tools": [{"name": "gm_search", "needs": []}],
     "proxy_env": "", "tool_count": 2, "timeout": 60, "switch": "PEYDA_GMAPS",
     "hint": "places and local businesses: address, phone, website, rating (Google Maps Scraper Kit)"},
]

# Which services answer a domain first (the rest follow, by weight).
LEAD = {"shopping": ["digikala", "torob", "emalls"], "classifieds": ["divar", "sheypoor"],
        "food": ["snapp", "tapsifood"], "travel_tickets": ["mrbilit", "alibaba", "flytoday"],
        "health": ["paziresh24", "doctoreto"], "prices": ["tgju", "iran_gold"],
        "maps": ["neshan", "gmaps", "balad"]}


def main(path: str) -> None:
    servers = {s["name"]: s for s in json.loads(Path(path).read_text())}
    out, pins, problems = [], [], []
    for sid, (pkg, domains, tools, extra) in ROUTES.items():
        s = servers.get(pkg)
        if not s:
            problems.append(f"{sid}: no server named {pkg}")
            continue
        names = {t["name"] for t in s["tools"]}
        entry_tools = []
        for t in tools:
            t = {"name": t} if isinstance(t, str) else dict(t)
            if t["name"] not in names:
                problems.append(f"{sid}: {pkg} has no tool {t['name']} (has: {', '.join(sorted(names))[:200]})")
                continue
            t.setdefault("needs", [])
            entry_tools.append(t)
        if extra.get("geocode") and extra["geocode"] not in names:
            problems.append(f"{sid}: {pkg} has no geocode tool {extra['geocode']}")
        proxy = [e["name"] for e in s.get("env", []) if e["name"].endswith("_PROXY")]
        entry = {
            "id": sid, "package": pkg, "version": s["version"], "title": s["title"], "site": s["site"],
            "domains": domains, "tools": entry_tools,
            "proxy_env": proxy[0] if proxy else "",
            "tool_count": s["tool_count"],
        }
        if extra.get("resolve") and extra["resolve"] not in names:
            problems.append(f"{sid}: {pkg} has no resolver tool {extra['resolve']}")
        if extra.get("resolve_specialty") and extra["resolve_specialty"] not in names:
            problems.append(f"{sid}: {pkg} has no specialty lookup {extra['resolve_specialty']}")
        for key in ("geocode", "resolve", "resolve_specialty"):
            if extra.get(key):
                entry[key] = extra[key]
        if extra.get("hint"):
            entry["hint"] = extra["hint"]
        out.append(entry)
        pins.append(f"{pkg}=={s['version']}")
    out.extend(LOCAL)
    if problems:
        sys.exit("\n".join(problems))
    here = Path(__file__).resolve().parent.parent
    (here / "peyda" / "services.json").write_text(
        json.dumps({"lead": LEAD, "services": out}, ensure_ascii=False, indent=1) + "\n", encoding="utf8")
    (here / "requirements-services.txt").write_text("\n".join(sorted(pins)) + "\n")
    print(f"{len(out)} services written ({len(LOCAL)} of Peyda's own); {len(pins)} packages pinned")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "servers.json")
