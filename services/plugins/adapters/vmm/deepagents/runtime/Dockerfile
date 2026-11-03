# syntax=docker/dockerfile:1.7
# Aseman's deep agents runtime. The node runs it as a Nomad service VM
# (see ../runtime.go); agents reach the platform only through the node.
# DeepSeek Harness (dsh) for the agentic engine (Admin → Agentic engine →
# DeepSeek Harness). Pinned; 0.2.2-alpha.* adds Agent Teams and
# --approval-policy, which the engine detects and uses when present.
ARG DSH_VERSION=0.2.1-rc.5
FROM node:22-bookworm-slim AS dsh
ARG DSH_VERSION
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/extra_ca; fi; \
    npm install --global --no-audit --no-fund --prefix /opt/dsh "@deepseek-ai/dsh@${DSH_VERSION}" \
 && /opt/dsh/bin/dsh --version

FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    ASEMAN_RUNTIME_PORT=8000 ASEMAN_DATA_DIR=/data

WORKDIR /app
COPY requirements.txt .
# Optional extra CA for building behind a TLS-intercepting proxy:
#   docker build --secret id=extra_ca,src=/path/ca.crt ...
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then \
      cat /etc/ssl/certs/ca-certificates.crt /run/secrets/extra_ca > /tmp/ca.crt; export PIP_CERT=/tmp/ca.crt; \
    fi; \
    pip install --no-cache-dir -r requirements.txt && rm -f /tmp/ca.crt
# OpenCode CLI for the agentic engine (Admin → Agentic engine). Each turn
# gets its own config under $ASEMAN_DATA_DIR/opencode-engine and a free model
# on OpenCode's gateway. This is not the sandbox programmer (/etc/opencode,
# aseman-appui, the metered Aseman LLM proxy).
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://opencode.ai/v2/install | bash -s -- --version 2.1.4 --no-modify-path \
 && ln -sf /root/.opencode/bin/opencode /usr/local/bin/opencode 2>/dev/null || ln -sf /root/.local/bin/opencode /usr/local/bin/opencode 2>/dev/null || ln -sf /root/.config/opencode/bin/opencode /usr/local/bin/opencode 2>/dev/null || true \
 && command -v opencode >/dev/null && opencode --version
# DeepSeek Harness: Node and the dsh CLI. Each turn boots dsh's headless
# profile with an Aseman overlay under $ASEMAN_DATA_DIR/dsh-engine; its own
# memory plugin ships in aseman_agents/deepseek_engine/plugins.
COPY --from=dsh /usr/local/bin/node /usr/local/bin/node
COPY --from=dsh /opt/dsh /opt/dsh
RUN ln -sf /opt/dsh/bin/dsh /usr/local/bin/dsh && dsh --version
COPY aseman_agents ./aseman_agents

VOLUME ["/data"]
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
  CMD python -c "import os,urllib.request;r=urllib.request.Request('http://127.0.0.1:'+os.environ['ASEMAN_RUNTIME_PORT']+'/healthz',headers={'X-Aseman-Runtime':os.environ.get('ASEMAN_RUNTIME_SECRET','')});urllib.request.urlopen(r,timeout=2)" || exit 1
CMD ["python", "-m", "aseman_agents"]
