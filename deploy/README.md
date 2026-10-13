# Deploying

Two workflows, independent of each other:

1. [`deploy.yml`](../.github/workflows/deploy.yml): **every push to `main`**. Copies the repo to your server
   over SSH (never touching the server's own `.env` and `services/configs/config.yml`) and runs
   `docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml up -d --build`.
2. [`sandbox-image.yml`](../.github/workflows/sandbox-image.yml): **only when `deploy/sandbox-computer/**` changes**
   (or run by hand from the Actions tab). Builds the sandbox computer (amd64 + arm64) and pushes
   `ghcr.io/<owner>/tradera-sandbox-computer:latest` (and `:<sha>`). The workflow file itself is in the path
   filter, so the push that first adds it builds the first image.

## Fast deploys from your own machine (`[self-hosted]`)

By default the **server** builds every image, which takes about 8 minutes on a small server. Put
`[self-hosted]` anywhere in a commit message and the deploy runs on **your own machine** instead: it builds the
images natively, pushes them to your private GHCR, and the server only pulls and restarts. Without the
flag nothing changes. Your server is arm64, so use an Apple Silicon Mac (or any arm64 Linux box): an x86
machine would build under emulation, which is slower than the server.

One-time setup on your Mac:

1. Docker Desktop installed and **running** when you push.
2. GitHub → your repo → **Settings → Actions → Runners → New self-hosted runner → macOS (ARM64)**.
   Run the commands it shows (download, `./config.sh --url … --token …`). Keep the default labels
   (`self-hosted`, `macOS`). Start it with `./run.sh`, or `sudo ./svc.sh install && sudo ./svc.sh start` to
   have it start at login.
3. Keep this repo **private**: a self-hosted runner runs the repo's workflow code on your machine.

Then `git commit -m "Fix the thing [self-hosted]" && git push`. The job waits if the Mac is off or asleep (push
without the flag instead). To skip Actions entirely, run it by hand from the repo root:

```bash
DEPLOY_HOST=<server ip> DEPLOY_USER=ubuntu GHCR_USER=<you> GHCR_TOKEN=<token with write:packages> ./deploy/ship.sh
BUILD_ONLY=1 ./deploy/ship.sh     # just build locally, push and deploy nothing
```

How it works: [`ship.sh`](ship.sh) builds the four images in parallel for the server's CPU, pushes them as
`ghcr.io/<owner>/tradera-prod-{node,web,agents,sandbox}:<commit>`, logs the server in to GHCR for
the pull only (and logs out again), re-tags them to the names `docker-compose.yml` uses, and runs
`docker compose up -d --no-build`. Runtime settings remain in the server's `.env`.
The workflow's own token is enough for GHCR; no extra secret.

The stack on the server: postgres, nomad, the deep agents runtime, the node, the
web app, and **Caddy** as the only public entrypoint (HTTPS, automatic certificates).

## One-time setup

### 1. The server (EC2 or any Linux box)
- Docker Engine with Compose **≥ 2.24** (`docker compose version`).
- Ports **80, 443** (and 443/udp) open in the security group / firewall; 22 for SSH.
- A user that can run `docker` (`sudo usermod -aG docker $USER`) and write to the
  deploy path (default `/opt/tradera`: `sudo mkdir -p /opt/tradera && sudo chown $USER /opt/tradera`).
- 4 GB RAM or more is comfortable (the web image is built on the server).

### 2. DNS
Point both names at the server's IP (A/AAAA records):

| Name | Serves |
|------|--------|
| `app.example.com` | the web app (it also proxies `/v1` to the node on its own origin) |
| `api.example.com` | the node's API directly (native apps, webhooks, other nodes) |

### 3. The server's `.env` (your settings live here, not in GitHub)
Create it once on the server, in the deploy path:
```bash
ssh you@server
nano /opt/tradera/.env      # contents: see .env.example, minimum below
chmod 600 /opt/tradera/.env
```
Minimum:
```bash
APP_DOMAIN=app.example.com
API_DOMAIN=api.example.com
ACME_EMAIL=you@example.com
TRADERA_PUBLIC_URL=https://api.example.com
TRADERA_ADMIN_PASSWORD=<a long random password>
POSTGRES_PASSWORD=<a long random password>

# Node identity (admin handle, Google client, Modal token) is optional; create
# /opt/tradera/services/configs/config.yml from services/configs/config.example.yml
# and add TRADERA_CONFIG_FILE=./services/configs/config.yml to .env.

# Modal sandboxes instead of local docker ones (optional):
# TRADERA_SANDBOX_BACKEND=modal
# TRADERA_MODAL_TOKEN_ID=ak-...
# TRADERA_MODAL_TOKEN_SECRET=as-...
```
The platform needs nothing from GHCR: with the default `docker` sandbox backend the stack builds
its own `tradera/sandbox-computer` image. Only for **Modal** add to `.env`:
`TRADERA_SANDBOX_BACKEND=modal` and
`TRADERA_SANDBOX_IMAGE=ghcr.io/<owner-lowercase>/tradera-sandbox-computer:latest`.
The agents' memory server (OpenViking) needs nothing here: its root key
(`TRADERA_OPENVIKING_ROOT_KEY`) is generated into `.env` on the first deploy,
and its models are picked in the app under **Admin → Memory models**.
The projects' timelines (Utopia, on the stack's own Postgres) need nothing either:
the node's password there (`TRADERA_TIMELINE_PASSWORD`) is generated into `.env`
the same way. The Postgres image now carries pgvector (`deploy/postgres`, same
`postgres:16-alpine` base), so the existing data volume is used as it is.
Everything else in [`.env.example`](../.env.example) is optional. The
deploy stops with a clear message if `.env` is missing. Editing `.env` needs no
redeploy of code: run the `docker compose ... up -d` line from "Day to day".

### Repository secrets (Settings → Secrets and variables → Actions)
Only SSH access:

| Secret | Value |
|--------|-------|
| `DEPLOY_HOST` | server hostname or IP |
| `DEPLOY_USER` | SSH user |
| `DEPLOY_SSH_KEY` | private key (the matching public key in the server's `~/.ssh/authorized_keys`) |
| `DEPLOY_PATH` | optional, default `/opt/tradera` |

### Dev server (optional): every push to `dev`
[`deploy-dev.yml`](../.github/workflows/deploy-dev.yml) deploys the `dev` branch to a separate server,
the same way `deploy.yml` deploys `main`. Production is never touched: it uses its own secrets and refuses
to run if `DEPLOY_HOST_DEV` is empty or equals `DEPLOY_HOST`.

| Secret | Value |
|--------|-------|
| `DEPLOY_HOST_DEV` | the dev server's hostname or IP |
| `DEPLOY_USER_DEV` | SSH user |
| `DEPLOY_SSH_KEY_DEV` | private key (public half in the dev server's `~/.ssh/authorized_keys`) |
| `DEPLOY_PATH_DEV` | optional, default `/opt/tradera` |

On the dev server, once: install Docker with Compose >= 2.24, create the deploy folder, and write its own
`.env` (never copied from production): `APP_DOMAIN`, `API_DOMAIN`, `ACME_EMAIL`, `TRADERA_PUBLIC_URL`, a
**strong `TRADERA_ADMIN_PASSWORD`**, a separate Modal token with `TRADERA_MODAL_ENVIRONMENT=dev`, and
`TRADERA_SANDBOX_IMAGE=ghcr.io/<owner>/tradera-sandbox-computer:dev`. Point both domains at the server
(A records), open ports 80/443, and add the dev web origin to the Google OAuth client. The `:dev` sandbox image
is published by `sandbox-image.yml` when `deploy/sandbox-computer/**` changes on `dev` (`:latest` stays main-only),
and, like `:latest`, its GHCR package must be made public for Modal.

### 4. Make the GHCR package public
New GHCR packages are not always public. After the first run: GitHub → your profile/org →
**Packages** → `tradera-sandbox-computer` → **Package settings** → **Change visibility → Public**.
(GitHub has no API for this, so it is a one-time click. Only Modal needs it: it pulls the image
without credentials. The deploy does not use it.)

## Where the domains are set
- **Names:** `APP_DOMAIN` / `API_DOMAIN` / `ACME_EMAIL` in the server's `.env`.
- **Routing:** [`deploy/caddy/Caddyfile`](caddy/Caddyfile), one block per domain. Add another
  domain by adding a block (and its DNS record); Caddy fetches its certificate on the next reload.
- **Wiring:** [`deploy/docker-compose.prod.yml`](docker-compose.prod.yml) adds the `caddy` service and
  keeps `web` and the node on the server's loopback so only Caddy is public.
- The web container's own `app/deploy/nginx.conf` stays HTTP-only on port 80 inside the
  stack; do not put domains there.

The node answers cross-origin requests from any origin, so giving the API its own domain needs no extra CORS setup; the web app keeps using its same-origin `/v1` either way.

## Day to day
```bash
ssh you@server
cd /opt/tradera
docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml ps
docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml logs -f tradera
```
Data lives in the `postgres-data` and `tradera-data` volumes; the workflow never deletes them.

## Credential storage

Account passwords are stored as bcrypt hashes, never as recoverable plaintext. Changing
`TRADERA_ADMIN_PASSWORD` only sets the password of a newly bootstrapped account; to change
an existing administrator's password, use Profile settings or password recovery.
`/admin/health` checks the current stored hashes of active administrators, including renamed
and role-based admins, rather than the bootstrap environment variable.

LLM provider API keys and desktop proxy connect tokens are encrypted with AES-256-GCM,
using a domain-separated key derived from the persistent node identity. Each ciphertext is
bound to its record ID. Existing plaintext records are upgraded when their namespace starts;
a failed upgrade or an undecryptable credential prevents startup. MCP connection/OAuth
credentials and account private/recovery keys already use authenticated encryption. Generic
admin table responses redact credentials and hashes.

Back up **both** database and `tradera-data` together. Preserve the node identity key in
`/app/data` (or the configured identity key); replacing it makes stored credentials unreadable.
Do not rotate/delete the identity key without decrypting and re-encrypting credentials first.
Database encryption does not encrypt deployment `.env` files, YAML configuration, Docker
environment metadata, or old backups. Supply deployment secrets through your infrastructure's
secret manager, restrict files to the server owner (`chmod 600`), and use encrypted disks/backups.
Never put secret API keys in client build arguments; those values are embedded in the client bundle.
