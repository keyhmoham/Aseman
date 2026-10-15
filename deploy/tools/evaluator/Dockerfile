# The evaluator tool: a managed docker backend of Tradera (an MCP server on
# :8080/mcp) with a real headless browser. The official Playwright image ships
# Chromium and its OS dependencies — the same base davinci-agent's
# browser_automation tool uses.
FROM mcr.microsoft.com/playwright/python:v1.49.0-noble

WORKDIR /app
RUN pip install --no-cache-dir playwright==1.49.0 cryptography==44.0.0 \
 && python -m playwright install chromium

COPY evaluator /app/evaluator

ENV PYTHONUNBUFFERED=1 PORT=8080
EXPOSE 8080
CMD ["python", "-m", "evaluator.server"]
