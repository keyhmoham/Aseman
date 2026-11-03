# Aseman's agent runtime: DeepSeek Harness (dsh) as a long-lived host with
# Aseman's plugins (lib/). The node schedules it as a Nomad service and talks
# to it with the runtime secret; agents reach the platform only through the
# node's gateway with their turn's token.
FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    ASEMAN_DATA_DIR=/data \
    ASEMAN_RUNTIME_PORT=8000

WORKDIR /opt/aseman-harness
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
 && node -e "require.resolve('@deepseek-ai/dsh/package.json')" \
 && npm cache clean --force
COPY bin ./bin
COPY lib ./lib

RUN mkdir -p /data && chown -R node:node /data
USER node
VOLUME /data
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=60s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.ASEMAN_RUNTIME_PORT+'/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
CMD ["node", "bin/aseman-harness.js"]
