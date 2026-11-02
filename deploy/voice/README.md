# Local voice sidecar (STT + TTS)

Compact OpenAI-compatible speech server for Aseman’s live voice loop:

1. App mic → `users.voice_turn`
2. Node → this sidecar `/v1/audio/transcriptions` (Parakeet TDT 0.6B V3 via onnx-asr)
3. Node → Aseman brain agent
4. Node → this sidecar `/v1/audio/speech` (Kokoro-ONNX)
5. App plays the WAV reply

## Run with docker compose (recommended)

The stack includes a `voice` service. From the repo root:

```bash
docker compose up -d --build voice
# or full stack: ./aseman.sh up
```

From the **aseman** container the base URL is the compose DNS name:

```text
http://voice:8091/v1
```

Do **not** use `http://127.0.0.1:8091` in Admin when the node runs in Docker —
that address is the aseman container itself, not this sidecar.

Host port `${VOICE_PORT:-8091}` is published only for debugging
(`curl http://127.0.0.1:8091/healthz` from the host).

## Run on the host (without compose)

```bash
cd deploy/voice
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python server.py
```

Then either:

- add the sidecar to the same Docker network and use `http://voice:8091/v1`, or
- point the provider at `http://host.docker.internal:8091/v1` (Linux may need
  `extra_hosts: ["host.docker.internal:host-gateway"]` on the aseman service).

## Wire into Aseman

Admin → AI → Providers: kind **OpenAI**, base URL `http://voice:8091/v1`,
API key = `VOICE_API_KEY` or any placeholder (e.g. `local`).

Admin → AI → Models: add / mark:

- `parakeet-tdt-0.6b-v3` — capability **Transcription**
- `kokoro` — capability **Speech**

Admin → AI → Voice: enable Transcription → `parakeet-tdt-0.6b-v3`, Speech → `kokoro`
(optional voice name e.g. `af_heart`).

## Env

| Variable | Default | Meaning |
| --- | --- | --- |
| `VOICE_HOST` | `0.0.0.0` | Bind address |
| `VOICE_PORT` | `8091` | Bind / published port |
| `PARAKEET_MODEL` | `nemo-parakeet-tdt-0.6b-v3` | onnx-asr / Hugging Face model id |
| `PARAKEET_DEVICE` | `cpu` | `cpu` or `cuda` |
| `PARAKEET_QUANTIZATION` | `int8` | onnx-asr quantization (`int8` / empty for fp32) |
| `STT_MODEL_ID` | `parakeet-tdt-0.6b-v3` | Id exposed on `/v1/models` for Admin |
| `KOKORO_VOICE` | `af_heart` | Kokoro speaker id |
| `VOICE_API_KEY` | _(empty)_ | If set, require `Authorization: Bearer …` |
