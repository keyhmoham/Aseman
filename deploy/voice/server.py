#!/usr/bin/env python3
"""OpenAI-compatible STT + TTS sidecar for Aseman live voice.

Endpoints used by llm.Transcribe / llm.Speak:
  POST /v1/audio/transcriptions  (multipart: file, model)
  POST /v1/audio/speech          (json: model, input, voice)
  GET  /v1/models
"""

from __future__ import annotations

import io
import os
import subprocess
import tempfile
from functools import lru_cache
from typing import Optional

import numpy as np
import soundfile as sf
import uvicorn
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

HOST = os.getenv("VOICE_HOST", "0.0.0.0")
PORT = int(os.getenv("VOICE_PORT", "8091"))
API_KEY = os.getenv("VOICE_API_KEY", "").strip()
# onnx-asr model id (Hugging Face hub name). Default is NVIDIA Parakeet TDT 0.6B V3.
PARAKEET_MODEL = os.getenv("PARAKEET_MODEL", "nemo-parakeet-tdt-0.6b-v3").strip()
PARAKEET_DEVICE = os.getenv("PARAKEET_DEVICE", "cpu").strip().lower()
PARAKEET_QUANTIZATION = os.getenv("PARAKEET_QUANTIZATION", "int8").strip() or None
# Public model id shown to Admin → AI (capability Transcription).
STT_MODEL_ID = os.getenv("STT_MODEL_ID", "parakeet-tdt-0.6b-v3").strip()
KOKORO_VOICE = os.getenv("KOKORO_VOICE", "af_heart")
KOKORO_MODEL = os.getenv("KOKORO_MODEL", "")
KOKORO_VOICES = os.getenv("KOKORO_VOICES", "")
TARGET_SR = 16000

app = FastAPI(title="Aseman voice sidecar", version="1.1.0")


def require_auth(authorization: Optional[str] = Header(default=None)) -> None:
    if not API_KEY:
        return
    if not authorization or authorization.strip() != f"Bearer {API_KEY}":
        raise HTTPException(status_code=401, detail="unauthorized")


def _parakeet_providers():
    if PARAKEET_DEVICE in ("cuda", "gpu"):
        return ["CUDAExecutionProvider", "CPUExecutionProvider"]
    return None


@lru_cache(maxsize=1)
def parakeet():
    import onnx_asr

    kwargs = {"quantization": PARAKEET_QUANTIZATION}
    providers = _parakeet_providers()
    if providers:
        kwargs["providers"] = providers
    return onnx_asr.load_model(PARAKEET_MODEL, **kwargs)


@lru_cache(maxsize=1)
def kokoro():
    from kokoro_onnx import Kokoro

    model = KOKORO_MODEL or os.environ.get("KOKORO_MODEL", "")
    voices = KOKORO_VOICES or os.environ.get("KOKORO_VOICES", "")
    if not model or not voices or not os.path.isfile(model) or not os.path.isfile(voices):
        raise RuntimeError(
            "Kokoro model files missing. Set KOKORO_MODEL and KOKORO_VOICES "
            "(entrypoint downloads them into /models on first start)."
        )
    return Kokoro(model, voices)


def _resample(audio: np.ndarray, sr: int, target: int = TARGET_SR) -> np.ndarray:
    if sr == target:
        return audio.astype(np.float32, copy=False)
    if audio.size == 0:
        return audio.astype(np.float32, copy=False)
    # Linear resample — fine for short voice utterances.
    n = max(1, int(round(audio.shape[0] * target / sr)))
    x_old = np.linspace(0.0, 1.0, num=audio.shape[0], endpoint=False)
    x_new = np.linspace(0.0, 1.0, num=n, endpoint=False)
    return np.interp(x_new, x_old, audio.astype(np.float32)).astype(np.float32)


def load_pcm16k(data: bytes, filename: str) -> tuple[np.ndarray, float]:
    """Decode uploaded audio to mono float32 @ 16 kHz.

    We feed NumPy to onnx-asr so webm/ogg/mp3 and non-PCM WAV still work
    via soundfile or ffmpeg.
    """
    try:
        audio, sr = sf.read(io.BytesIO(data), dtype="float32", always_2d=True)
        audio = audio.mean(axis=1)
        pcm = _resample(audio, int(sr))
        return pcm, float(len(pcm)) / TARGET_SR
    except Exception:
        pass

    # ffmpeg fallback for webm/ogg/mp3/etc.
    suffix = os.path.splitext(filename or "speech.wav")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as src:
        src.write(data)
        src.flush()
        try:
            out = subprocess.check_output(
                [
                    "ffmpeg",
                    "-nostdin",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-i",
                    src.name,
                    "-ac",
                    "1",
                    "-ar",
                    str(TARGET_SR),
                    "-f",
                    "f32le",
                    "pipe:1",
                ],
                stderr=subprocess.STDOUT,
            )
        except subprocess.CalledProcessError as e:
            raise HTTPException(
                status_code=400,
                detail=f"could not decode audio: {e.output[-300:].decode(errors='ignore')}",
            ) from e
    pcm = np.frombuffer(out, dtype=np.float32).copy()
    return pcm, float(len(pcm)) / TARGET_SR


class SpeechIn(BaseModel):
    model: str = "kokoro"
    input: str = Field(..., min_length=1)
    voice: str = ""
    response_format: str = "mp3"
    speed: float = 1.0


@app.get("/healthz")
def healthz():
    return {"ok": True, "stt": STT_MODEL_ID, "tts": "kokoro"}


@app.get("/v1/models")
def models(_: None = Depends(require_auth)):
    return {
        "object": "list",
        "data": [
            {"id": STT_MODEL_ID, "object": "model", "owned_by": "aseman-voice"},
            {"id": "parakeet-v3", "object": "model", "owned_by": "aseman-voice"},
            {"id": "kokoro", "object": "model", "owned_by": "aseman-voice"},
        ],
    }


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form(default="parakeet-tdt-0.6b-v3"),
    response_format: str = Form(default="json"),
    _: None = Depends(require_auth),
):
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="empty audio")
    pcm, duration = load_pcm16k(data, file.filename or "speech.wav")
    if pcm.size < TARGET_SR * 0.05:
        raise HTTPException(status_code=400, detail="audio too short")
    try:
        text = parakeet().recognize(pcm, sample_rate=TARGET_SR)
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"stt failed: {e}") from e
    if not isinstance(text, str):
        text = getattr(text, "text", None) or str(text)
    text = text.strip()
    if response_format == "text":
        return Response(content=text, media_type="text/plain")
    return JSONResponse({"text": text, "duration": duration, "model": model or STT_MODEL_ID})


@app.post("/v1/audio/speech")
def speech(body: SpeechIn, _: None = Depends(require_auth)):
    text = body.input.strip()
    if not text:
        raise HTTPException(status_code=400, detail="nothing to say")
    # OpenAI clients often send "alloy"; map unknown names to the local default.
    requested = (body.voice or "").strip()
    voice = requested or KOKORO_VOICE
    try:
        samples, sample_rate = kokoro().create(text, voice=voice, speed=body.speed)
    except Exception as first:
        if voice != KOKORO_VOICE:
            try:
                samples, sample_rate = kokoro().create(text, voice=KOKORO_VOICE, speed=body.speed)
            except Exception as e:
                raise HTTPException(status_code=503, detail=f"tts failed: {e}") from e
        else:
            raise HTTPException(status_code=503, detail=f"tts failed: {first}") from first
    audio = np.asarray(samples, dtype=np.float32)
    buf = io.BytesIO()
    sf.write(buf, audio, sample_rate, format="WAV")
    return Response(content=buf.getvalue(), media_type="audio/wav")


if __name__ == "__main__":
    uvicorn.run("server:app", host=HOST, port=PORT, reload=False)
