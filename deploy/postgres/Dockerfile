# The node's Postgres, with pgvector: the stack's one database server. The
# node keeps its records in it, the spaces' timelines, and the agents' memory,
# whose recall by meaning needs the vector extension.
#
# Same base as before (postgres:16-alpine), so an existing data volume is
# used as it is. pgvector is compiled for any CPU of the platform
# (OPTFLAGS=""), since images are built on one machine and run on another.
FROM postgres:16-alpine

ARG PGVECTOR_VERSION=v0.8.0

RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then cat /run/secrets/extra_ca >> /etc/ssl/certs/ca-certificates.crt; fi; \
    apk add --no-cache --virtual .build-deps build-base git \
 && git clone --depth 1 --branch "$PGVECTOR_VERSION" https://github.com/pgvector/pgvector.git /tmp/pgvector \
 && make -C /tmp/pgvector OPTFLAGS="" with_llvm=no \
 && make -C /tmp/pgvector OPTFLAGS="" with_llvm=no install \
 && rm -rf /tmp/pgvector \
 && apk del .build-deps

