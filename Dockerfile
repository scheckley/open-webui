# syntax=docker/dockerfile:1

# WebUI frontend build
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
ENV NODE_OPTIONS="--max-old-space-size=4096"
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
    TIKTOKEN_ENCODING_NAME=cl100k_base \
    HOME=/app/backend \
    PATH=$PATH:/app/backend/.local/bin \
    DEBIAN_FRONTEND=noninteractive

WORKDIR /app/backend

# Install only required dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    build-essential \
    pandoc \
    ffmpeg \
    libavcodec-extra \
    gcc \
    netcat-openbsd \
    libsm6 \
    libxext6 && \
    # Cleanup
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    # Create non-root user with arbitrary user ID for OpenShift
    addgroup --gid 1000 appgroup && \
    adduser --uid 1000 --gid 1000 --disabled-password --gecos "" appuser && \
    mkdir -p /app/backend/data /app/backend/cache && \
    chown -R appuser:appgroup /app

USER 1000

# Install Python dependencies
COPY --chown=1000:1000 ./backend/requirements.txt ./requirements.txt
RUN pip3 install --user --no-cache-dir -r requirements.txt

# Install additional dependencies based on CUDA flag
RUN pip3 install --no-cache-dir uv && \
    if [ "$USE_CUDA" = "true" ]; then \
    # If you use CUDA the whisper and embedding model will be downloaded on first use
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/$USE_CUDA_DOCKER_VER --no-cache-dir && \
    uv pip install --system -r requirements.txt --no-cache-dir && \
    python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
    python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])"; \
    python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"; \
    else \
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir && \
    uv pip install --system -r requirements.txt --no-cache-dir && \
    python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
    python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])"; \
    python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"; \
    fi && \
    chown -R 1000:1000 /app/backend/data/

RUN mkdir -p /app/backend/open_webui/static && \
    chmod -R 777 /app/backend/open_webui/static

# Copy built frontend files
COPY --chown=1000:1000 --from=build /app/build /app/build
COPY --chown=1000:1000 --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=1000:1000 --from=build /app/package.json /app/package.json

# Copy backend files
COPY --chown=1000:1000 ./backend ./

EXPOSE 8080

HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

CMD [ "bash", "start.sh" ]

