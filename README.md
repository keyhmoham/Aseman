# Aseman

The Aseman Flutter client: a federated social workspace app (chat, projects,
agents, apps, billing) talking to a **Decillion** node as its API.

```
Aseman/
├── app/        # Aseman Flutter client (web, iOS, Android, desktop) — see app/README.md
└── workflows/  # Decillion workflow installers; aseman-peyda/ builds the Peyda search platform
```

## Quickstart (Docker)

Docker with the Compose plugin is the only prerequisite.

```bash
# Build + serve the client. Hot reload is on by default (edits under app/
# reload the running app). Talks to https://preview.decillionai.com.
./aseman.sh up

# Talk to a self-hosted Decillion stack on the host's own localhost:8080 instead.
./aseman.sh up --local

# Serve the release web build instead of the debug hot-reload server.
./aseman.sh up --no-hot-reload

./aseman.sh logs   # follow logs
./aseman.sh ps     # service status
./aseman.sh down   # stop
```

The client listens on `http://localhost:${WEB_PORT:-3000}`. Override the
Decillion node directly with `DECILLION_API_URL` (and, if its host isn't
derivable from the URL, `DECILLION_API_HOST`).

## Run without Docker

See [`app/README.md`](app/README.md) for running the Flutter app directly
(`flutter run`), its OAuth/sign-in flow, and the Elpian frontend engine.

## Deploying

[`render.yaml`](render.yaml) is a Render Blueprint that builds `app/` and
serves it against `DECILLION_API_URL`.
