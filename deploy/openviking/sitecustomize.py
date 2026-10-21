"""Tags OpenViking's model calls with the project they are for.

OpenViking calls its models through the node (see entrypoint.sh), which
charges each project for what its memory uses. A call says nothing about
whose memory it serves, but OpenViking knows:

* work done for a request, and background work such as extracting memories
  from a session, keeps its account in OpenViking's observability context
  (as its own metrics read it);
* the queue that embeds what was written calls AccountEmbeddingProvider.embed
  with the account the text belongs to.

Every request to the node carries that account in X-Aseman-Memory-Account.
A call made outside any account's work (OpenViking's own housekeeping)
carries none, and the node pays for it.

Python imports this module at startup (it is on PYTHONPATH). It patches
OpenViking's embedding provider when OpenViking imports it, so a plain Python
process (the entrypoint's config rendering) does not load OpenViking.
"""

import contextvars
import importlib.abc
import importlib.util
import os
import sys

_NODE = os.environ.get("OPENVIKING_NODE_URL", "").rstrip("/")
_HEADER = "X-Aseman-Memory-Account"
_EMBEDDING_MODULE = "openviking.config.embedding"

# The account an embedding is being made for (set around AccountEmbeddingProvider.embed).
_embedding_account = contextvars.ContextVar("aseman_embedding_account", default=None)


def _account():
    account = _embedding_account.get()
    if account:
        return str(account)
    try:
        from openviking.observability.context import get_root_observability_context

        root = get_root_observability_context()
    except Exception:  # noqa: BLE001 - tagging must never break a call
        return None
    account = getattr(root, "account_id", None) if root is not None else None
    return str(account) if account else None


def _tag(request):
    if str(request.url).startswith(_NODE + "/"):
        account = _account()
        if account:
            request.headers[_HEADER] = account


def _install_http():
    import httpx

    send, asend = httpx.Client.send, httpx.AsyncClient.send

    def tagged_send(self, request, *args, **kwargs):
        _tag(request)
        return send(self, request, *args, **kwargs)

    async def tagged_asend(self, request, *args, **kwargs):
        _tag(request)
        return await asend(self, request, *args, **kwargs)

    httpx.Client.send = tagged_send
    httpx.AsyncClient.send = tagged_asend


def _patch_embedding(module):
    provider = getattr(module, "AccountEmbeddingProvider", None)
    embed = getattr(provider, "embed", None)
    if embed is None:
        return

    async def embed_for_account(self, account_id, *args, **kwargs):
        token = _embedding_account.set(account_id)
        try:
            return await embed(self, account_id, *args, **kwargs)
        finally:
            _embedding_account.reset(token)

    provider.embed = embed_for_account


class _PatchEmbeddingOnImport(importlib.abc.MetaPathFinder):
    """Patches OpenViking's embedding provider as its module is loaded."""

    def find_spec(self, name, path=None, target=None):
        if name != _EMBEDDING_MODULE:
            return None
        sys.meta_path.remove(self)
        spec = importlib.util.find_spec(name)
        if spec is None or spec.loader is None or not hasattr(spec.loader, "exec_module"):
            return spec
        loader = spec.loader
        exec_module = loader.exec_module

        def exec_and_patch(module):
            exec_module(module)
            try:
                _patch_embedding(module)
            except Exception:  # noqa: BLE001
                pass

        loader.exec_module = exec_and_patch
        return spec


if _NODE:
    try:
        _install_http()
        sys.meta_path.insert(0, _PatchEmbeddingOnImport())
    except Exception:  # noqa: BLE001
        pass
