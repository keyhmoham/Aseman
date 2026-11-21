"""Can this computer reach what the install downloads?

Asks the computer's network proxy (HTTPS_PROXY) for a tunnel to each host and
prints the proxy's own answer: a refusal by the project's network policy is
403 and says so, a host it allowed but could not reach is 502 and says why.
Python's HTTP libraries hide that text, so a download that fails deep inside
an installer is hard to read. With no proxy it connects directly.

    python3 scripts/netcheck.py        exit 1 when a host the install needs is out of reach
"""
from __future__ import annotations

import os
import shutil
import socket
import sys
from urllib.parse import urlparse

# (host, what needs it, required)
def wanted(env: dict[str, str]) -> list[tuple[str, str, bool]]:
    model_cached = os.path.isdir(os.path.join(env.get("HF_HOME") or "/workspace/.cache/huggingface", "hub")) and any(
        d.startswith("models--") for d in os.listdir(os.path.join(env.get("HF_HOME") or "/workspace/.cache/huggingface", "hub")))
    hub = urlparse(env.get("HF_ENDPOINT") or "https://huggingface.co").hostname or "huggingface.co"
    return [
        ("pypi.org", "Python packages", True),
        ("files.pythonhosted.org", "Python packages", True),
        ("download.pytorch.org", "CPU PyTorch (the index)", True),
        ("download-r2.pytorch.org", "CPU PyTorch (the wheels are served from here)", True),
        (hub, "the GLiNER2 model" + (" (cached already)" if model_cached else ""), not model_cached),
        ("cas-bridge.xethub.hf.co", "model files (the xet store)", False),
    ] + gmaps_hosts(env)


def gmaps_hosts(env: dict[str, str]) -> list[tuple[str, str, bool]]:
    """The Google Maps service's: its engine's source and Chrome, needed only until they are
    installed, and Google Maps itself, which the service needs and the install does not."""
    if env.get("PEYDA_GMAPS", "1").strip() == "0":
        return []
    kit = os.path.join(env.get("PEYDA_GMAPS_KIT") or "/workspace/.gmaps-kit")
    have_kit = os.path.isfile(os.path.join(kit, ".peyda-commit"))
    have_chrome = os.path.isdir(os.path.join(kit, ".engine", "chrome")) or any(
        shutil.which(b) for b in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser"))
    return [
        ("codeload.github.com", "the Google Maps Scraper Kit's source" + (" (installed already)" if have_kit else ""), not have_kit),
        ("storage.googleapis.com", "Chrome for the Google Maps engine" + (" (a Chrome is here already)" if have_chrome else ""), not have_chrome),
        ("www.google.com", "Google Maps, which the Google Maps service searches", False),
    ]


def probe(host: str, proxy: str | None, timeout: float = 10.0) -> tuple[bool, str]:
    """(reachable, what the network said)."""
    try:
        if not proxy:
            socket.create_connection((host, 443), timeout=timeout).close()
            return True, "direct connection ok"
        p = urlparse(proxy if "://" in proxy else "http://" + proxy)
        with socket.create_connection((p.hostname, p.port or 3128), timeout=timeout) as s:
            s.settimeout(timeout)
            s.sendall(f"CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\n\r\n".encode())
            data = b""
            while b"\r\n\r\n" not in data and len(data) < 4096:
                chunk = s.recv(1024)
                if not chunk:
                    break
                data += chunk
            head, _, body = data.partition(b"\r\n\r\n")
            if not body and head.count(b"\r\n") >= 2:
                s.settimeout(1.0)
                try:
                    body = s.recv(512)
                except OSError:
                    pass
        status = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        if b" 200" in head.split(b"\r\n", 1)[0]:
            return True, "tunnel ok"
        return False, (status + " " + body.decode("utf-8", "replace").strip())[:300]
    except OSError as e:
        return False, f"{type(e).__name__}: {e}"


def main() -> int:
    env = dict(os.environ)
    proxy = env.get("HTTPS_PROXY") or env.get("https_proxy")
    print(f"network check ({'through ' + proxy if proxy else 'direct'})")
    failed = []
    for host, why, required in wanted(env):
        ok, detail = probe(host, proxy)
        print(f"  {'ok  ' if ok else ('FAIL' if required else 'warn')}  {host}  ({why})" + ("" if ok else f": {detail}"))
        if not ok and required:
            failed.append((host, detail, why))
    if not failed:
        print("network check: ok")
        return 0
    print("network check: cannot reach " + ", ".join(h for h, _, _ in failed))
    for host, detail, why in failed:
        if "403" in detail and "policy" in detail:
            print(f"  {host}: the project's network policy refuses it. Run the workflow with manage_network=true (the default) or add the host to the project's allowlist.")
        elif "502" in detail or "timed out" in detail or "refused" in detail or "no such host" in detail:
            print(f"  {host}: the node could not reach it. If it is blocked from this node's network, "
                  + ("run the workflow with hf_endpoint=<a Hugging Face mirror's URL>." if "model" in why else "use a mirror or a proxy for it."))
    return 1


if __name__ == "__main__":
    sys.exit(main())
