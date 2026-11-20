"""scripts/netcheck.py reads a proxy's answer to CONNECT, including the reason it gives."""
import importlib.util
import socketserver
import threading
from pathlib import Path

spec = importlib.util.spec_from_file_location("netcheck", Path(__file__).resolve().parent.parent / "scripts" / "netcheck.py")
netcheck = importlib.util.module_from_spec(spec)
spec.loader.exec_module(netcheck)


class FakeProxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def serve():
    class H(socketserver.BaseRequestHandler):
        def handle(self):
            req = self.request.recv(1024).decode()
            host = req.split()[1].split(":")[0]
            if host == "open.example":
                self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            elif host == "policy.example":
                body = b"decillion-egress: the project's network policy (defaults_plus_allowlist) does not allow policy.example\n"
                self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            else:
                body = b"dial tcp 10.0.0.1:443: i/o timeout\n"
                self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: %d\r\n\r\n" % len(body) + body)

    srv = FakeProxy(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def test_a_tunnel_that_opens_is_reachable():
    srv, proxy = serve()
    try:
        assert netcheck.probe("open.example", proxy)[0] is True
    finally:
        srv.shutdown()


def test_a_policy_refusal_and_an_unreachable_host_are_told_apart_with_the_reason():
    srv, proxy = serve()
    try:
        ok, detail = netcheck.probe("policy.example", proxy)
        assert not ok and "403" in detail and "network policy" in detail
        ok, detail = netcheck.probe("down.example", proxy)
        assert not ok and "502" in detail and "i/o timeout" in detail
    finally:
        srv.shutdown()


def test_a_dead_proxy_is_an_unreachable_result_not_a_crash():
    ok, detail = netcheck.probe("open.example", "http://127.0.0.1:9", timeout=2)
    assert not ok and detail


def test_a_cached_model_makes_the_model_host_optional(tmp_path, monkeypatch):
    (tmp_path / "hub" / "models--fastino--gliner2.5-multi-v1").mkdir(parents=True)
    rows = {h: req for h, _, req in netcheck.wanted({"HF_HOME": str(tmp_path)})}
    assert rows["huggingface.co"] is False and rows["pypi.org"] is True
    mirror = {h: req for h, _, req in netcheck.wanted({"HF_HOME": str(tmp_path / "empty"), "HF_ENDPOINT": "https://mirror.example/x"})}
    assert mirror["mirror.example"] is True and "huggingface.co" not in mirror
    assert mirror["download-r2.pytorch.org"] is True
