# syntax=docker/dockerfile:1

# WebUI frontend build
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

# WebUI backend
FROM python:3.11-slim-bookworm AS base

# Use args
ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_CUDA_VER
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL

# Environment setup
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=${USE_CUDA} \
    USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    HOME=/app/backend \
    PATH=$PATH:/app/backend/.local/bin

WORKDIR /app/backend

# Add an unprivileged user
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl jq git build-essential pandoc ffmpeg libavcodec-extra gcc && \
    groupadd -g 1000 appuser && \
    useradd -m -u 1000 -g appuser appuser && \
    mkdir -p /app/backend/data /app/backend/cache && \
    chown -R appuser:appuser /app

USER appuser

# Install Python dependencies
COPY --chown=appuser:appuser ./backend/requirements.txt ./requirements.txt
RUN pip3 install --user --no-cache-dir -r requirements.txt

# Copy built frontend files
COPY --chown=appuser:appuser --from=build /app/build /app/build
COPY --chown=appuser:appuser --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=appuser:appuser --from=build /app/package.json /app/package.json

# Copy backend files
COPY --chown=appuser:appuser ./backend ./

EXPOSE 8080

HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

CMD [ "bash", "start.sh" ]

