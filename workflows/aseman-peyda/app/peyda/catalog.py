"""Which servers answer which kind of query: the iran-mcp servers, and Peyda's
own MCP servers in front of other engines (Google Maps, `module`)."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .frame import QueryFrame
from .lexicon import has_word

HERE = Path(__file__).resolve().parent
GENERAL = ("shopping", "classifieds", "news", "reference")


@dataclass
class ToolRoute:
    name: str
    needs: list[str] = field(default_factory=list)   # slots that must be present
    kw: list[str] = field(default_factory=list)      # words that select this tool among a server's
    default: bool = False                            # used when no tool's words matched
    args: dict[str, Any] | None = None               # static arguments; None = build from the frame
    resolve_args: dict[str, Any] = field(default_factory=dict)  # fixed arguments for the server's place lookup (a mode)
    symbols: dict[str, str] | None = None            # word in the query → symbol slug, for a price feed
    default_symbols: list[str] = field(default_factory=list)  # when no word matched


@dataclass
class Service:
    id: str
    package: str
    title: str
    site: str
    domains: list[str]
    tools: list[ToolRoute]
    version: str = ""
    proxy_env: str = ""
    geocode: str = ""      # tool that turns an address into coordinates
    resolve: str = ""      # tool that turns a place name into the code other tools take
    resolve_specialty: str = ""  # tool that turns a field of medicine into the slug a doctor search takes
    hint: str = ""
    module: str = ""       # a Python module of this app to run as the server (`python -m <module>`), not a package
    timeout: float = 0     # seconds a search on this server may take; 0 = the gateway's default

    def pick_tools(self, frame: QueryFrame) -> list[ToolRoute]:
        low = frame.normalized.lower()
        gated = [t for t in self.tools if t.kw]
        if not gated:
            return list(self.tools)
        chosen = [t for t in gated if any(has_word(low, k) for k in t.kw)]
        if not chosen:
            chosen = [t for t in gated if t.default]
        return chosen + [t for t in self.tools if not t.kw]


class Catalog:
    def __init__(self, services: list[Service], lead: dict[str, list[str]]) -> None:
        self.services = {s.id: s for s in services}
        self.lead = lead

    @classmethod
    def load(cls, path: str | os.PathLike[str] | None = None) -> "Catalog":
        raw = json.loads(Path(path or HERE / "services.json").read_text(encoding="utf8"))
        out: list[Service] = []
        for s in raw["services"]:
            switch = s.get("switch")  # an optional service is left out when its variable says 0
            if switch and os.environ.get(switch, "1").strip().lower() in ("0", "false", "no", "off"):
                continue
            out.append(Service(
                id=s["id"], package=s["package"], title=s["title"], site=s["site"], domains=s["domains"],
                tools=[ToolRoute(name=t["name"], needs=t.get("needs", []), kw=t.get("kw", []),
                                 default=t.get("default", False), args=t.get("args"),
                                 resolve_args=t.get("resolve_args", {}), symbols=t.get("symbols"),
                                 default_symbols=t.get("default_symbols", []))
                       for t in s["tools"]],
                version=s.get("version", ""), proxy_env=s.get("proxy_env", ""),
                geocode=s.get("geocode", ""), resolve=s.get("resolve", ""),
                resolve_specialty=s.get("resolve_specialty", ""), hint=s.get("hint", ""),
                module=s.get("module", ""), timeout=float(s.get("timeout", 0) or 0),
            ))
        return cls(out, raw.get("lead", {}))

    def route(
        self, frame: QueryFrame, max_services: int = 6,
        only: list[str] | None = None, exclude: list[str] | None = None,
        domains: list[str] | None = None,
    ) -> list[Service]:
        """The services to ask for a frame: those answering its best domains,
        lead services first, each only if it has a tool for this wording."""
        wanted = domains or frame.domain_names[:3]
        if not wanted:  # nothing recognised: ask the broad sources rather than none
            wanted = list(GENERAL)
            note = "no domain recognised: asked the general sources"
            if note not in frame.assumptions:
                frame.assumptions.append(note)
        banned = set(exclude or [])
        if only:
            pool = [self.services[i] for i in only if i in self.services and i not in banned]
        else:
            pool = []
            for dom in wanted:
                lead = [self.services[i] for i in self.lead.get(dom, []) if i in self.services]
                rest = [s for s in self.services.values() if dom in s.domains and s not in lead]
                for s in lead + rest:
                    if s.id not in banned and s not in pool:
                        pool.append(s)
        pool = [s for s in pool if s.pick_tools(frame)]
        return pool[:max_services]

    def describe(self) -> list[dict[str, Any]]:
        return [{"id": s.id, "title": s.title, "site": s.site, "domains": s.domains} for s in self.services.values()]
