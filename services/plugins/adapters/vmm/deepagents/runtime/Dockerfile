# syntax=docker/dockerfile:1.7
# Tradera's agent runtime. The node runs it as a Nomad service VM (see
# ../runtime.go); agents reach the platform only through the node. Each agent's
# backbone is a self-hosted OpenCode the runtime runs beside itself, and the
# swarm is orchestrated with LangChain Deep Agents (LangGraph).

# OpenCode: its standalone binary, and the plugin SDK its projects load,
# installed at build time so the runtime never goes to npm.
FROM node:22-slim AS opencode
ARG OPENCODE_VERSION=1.19.3
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/extra_ca; fi; \
    set -e; \
    npm install -g --no-audit --no-fund "opencode-ai@${OPENCODE_VERSION}"; \
    bin="$(find "$(npm root -g)" -type f -path '*/opencode-linux-*/bin/opencode' ! -path '*musl*' ! -path '*baseline*' | head -n1)"; \
    install -m 0755 "$bin" /usr/local/bin/opencode; \
    mkdir -p /opt/opencode/config/opencode; cd /opt/opencode/config/opencode; \
    printf '{"dependencies":{"@opencode-ai/plugin":"%s"}}\n' "$OPENCODE_VERSION" > package.json; \
    npm install --omit=dev --no-audit --no-fund

FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    TRADERA_RUNTIME_PORT=8000 TRADERA_DATA_DIR=/data \
    TRADERA_OPENCODE_BIN=/usr/local/bin/opencode TRADERA_OPENCODE_CONFIG_HOME=/opt/opencode/config

# ripgrep: OpenCode searches with it (its skills among others) and would
# otherwise download it on first use.
RUN apt-get update && apt-get install -y --no-install-recommends ripgrep && rm -rf /var/lib/apt/lists/*
COPY --from=opencode /usr/local/bin/opencode /usr/local/bin/opencode
COPY --from=opencode /opt/opencode /opt/opencode
WORKDIR /app
COPY requirements.txt .
# Optional extra CA for building behind a TLS-intercepting proxy:
#   docker build --secret id=extra_ca,src=/path/ca.crt ...
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then \
      cat /etc/ssl/certs/ca-certificates.crt /run/secrets/extra_ca > /tmp/ca.crt; export PIP_CERT=/tmp/ca.crt; \
    fi; \
    pip install --no-cache-dir -r requirements.txt && rm -f /tmp/ca.crt && opencode --version
COPY tradera_agents ./tradera_agents

VOLUME ["/data"]
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s \
  CMD python -c "import os,urllib.request;r=urllib.request.Request('http://127.0.0.1:'+os.environ['TRADERA_RUNTIME_PORT']+'/healthz',headers={'X-Tradera-Runtime':os.environ.get('TRADERA_RUNTIME_SECRET','')});urllib.request.urlopen(r,timeout=2)" || exit 1
CMD ["python", "-m", "tradera_agents"]
