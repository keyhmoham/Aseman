# syntax=docker/dockerfile:1.7
# Aseman's deep agents runtime. The node runs it as a Nomad service VM
# (see ../runtime.go); agents reach the platform only through the node.
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
COPY aseman_agents ./aseman_agents

VOLUME ["/data"]
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
  CMD python -c "import os,urllib.request;r=urllib.request.Request('http://127.0.0.1:'+os.environ['ASEMAN_RUNTIME_PORT']+'/healthz',headers={'X-Aseman-Runtime':os.environ.get('ASEMAN_RUNTIME_SECRET','')});urllib.request.urlopen(r,timeout=2)" || exit 1
CMD ["python", "-m", "aseman_agents"]
