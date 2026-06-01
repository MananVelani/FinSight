# backend/Dockerfile — Production-ready image for Railway
# Uses uv for fast, reproducible dependency installation

# ---- Stage 1: Dependencies ----
FROM python:3.12-slim AS dependencies

# Install uv
RUN pip install uv

WORKDIR /app

# Copy lockfile and project config for reproducible builds
COPY pyproject.toml uv.lock ./

# Create venv and install all dependencies using the lockfile
RUN uv venv .venv && \
    uv sync --frozen --no-dev

# ---- Stage 2: Production ----
FROM python:3.12-slim AS production

# System deps for sentence-transformers, Docling, audio processing
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    ffmpeg \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy installed packages from dependencies stage
COPY --from=dependencies /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONPATH="/app"

# Copy application code (excludes files in .dockerignore)
COPY . .

# Create required directories
RUN mkdir -p /app/uploads /app/data/bm25_indexes

# Non-root user for security
RUN useradd -m appuser && chown -R appuser:appuser /app
USER appuser

EXPOSE 7860

# Run migrations then start server on Hugging Face's required port 7860
CMD alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 7860 --workers 2
