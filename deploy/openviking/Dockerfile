# syntax=docker/dockerfile:1.7
# Self-hosted OpenViking (https://openviking.ai): the context database that
# keeps the agents' memory. The deep agents runtime reaches it on the stack's
# network (http://openviking:1933) in trusted mode, with the root key. Its
# models are the node's: it calls them through the node (see entrypoint.sh).
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

# volcengine-python-sdk is pinned: 5.0.51.post1 dropped the "ark" extra that
# openviking imports, and the server does not start without it.
# Optional extra CA for building behind a TLS-intercepting proxy:
#   docker build --secret id=extra_ca,src=/path/ca.crt ...
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then \
      cat /etc/ssl/certs/ca-certificates.crt /run/secrets/extra_ca > /tmp/ca.crt; export PIP_CERT=/tmp/ca.crt; \
    fi; \
    pip install --no-cache-dir openviking==0.5.0 "volcengine-python-sdk[ark]==5.0.51" && rm -f /tmp/ca.crt

COPY ov.conf /etc/openviking/ov.conf
# Tags each model call with the project it is for, so the node bills it.
COPY sitecustomize.py /opt/tradera/sitecustomize.py
ENV PYTHONPATH=/opt/tradera
COPY entrypoint.sh /usr/local/bin/openviking-entrypoint
RUN chmod +x /usr/local/bin/openviking-entrypoint

VOLUME ["/data"]
EXPOSE 1933
HEALTHCHECK --interval=15s --timeout=3s --start-period=30s \
  CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:1933/health',timeout=2)" || exit 1
ENTRYPOINT ["openviking-entrypoint"]
