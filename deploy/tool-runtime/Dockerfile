# Aseman tool runtime: runs a tool backend written for the Elpian VM (Dart
# or the Elpian JS subset) or for QuickJS, and serves its microtools over MCP.
#
#   docker build -t aseman/tool-runtime:v1 deploy/tool-runtime
#
# One image, three uses: Nomad runs it for managed tools; the sandbox computer
# image copies its /opt/aseman-tool-runtime for installed tools; and the
# stack runs it with --compiler for the node (compiling Elpian frontends to
# bytecode and describing backend programs).

# --- The Elpian VM for Node.js, with its compiler front-ends ---------------
# Built from the Elpian sources (elpian-wasm, `--features compiler`): the
# runtime links no other Elpian code. Pinned to a commit so builds repeat.
FROM public.ecr.aws/docker/library/rust:1-bookworm AS elpian
ARG ELPIAN_REPO=https://github.com/cosmopole-org/elpian.git
ARG ELPIAN_COMMIT=c1f8f84b4161cabf9ac8043ae07fcf0e8643bc08
RUN rustup target add wasm32-unknown-unknown \
 && cargo install wasm-pack --locked
RUN git init /src/elpian \
 && git -C /src/elpian fetch --depth 1 "$ELPIAN_REPO" "$ELPIAN_COMMIT" \
 && git -C /src/elpian checkout --quiet FETCH_HEAD
WORKDIR /src/elpian/rust/crates/elpian-wasm
# --no-opt: wasm-opt is downloaded from GitHub at build time; the unoptimized
# module is ~1.5 MB and fast enough for a server.
RUN wasm-pack build --release --no-opt --target nodejs --out-dir /out/elpian -- --features compiler

# --- The runtime --------------------------------------------------------------
FROM public.ecr.aws/docker/library/node:22-bookworm-slim
WORKDIR /opt/aseman-tool-runtime
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY server.mjs ./
COPY lib ./lib
COPY --from=elpian /out/elpian ./vendor/elpian
ENV PORT=8790
EXPOSE 8790
USER node
CMD ["node", "server.mjs"]
