FROM python:3.12-slim

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsndfile1 ffmpeg curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENV VOICE_HOST=0.0.0.0 \
    VOICE_PORT=8091 \
    PARAKEET_MODEL=nemo-parakeet-tdt-0.6b-v3 \
    PARAKEET_DEVICE=cpu \
    PARAKEET_QUANTIZATION=int8 \
    STT_MODEL_ID=parakeet-tdt-0.6b-v3 \
    KOKORO_DIR=/models \
    KOKORO_VOICE=af_heart

VOLUME ["/models"]
EXPOSE 8091
ENTRYPOINT ["./entrypoint.sh"]
