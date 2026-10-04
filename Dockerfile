# Image Similarity Benchmark - CPU image for Linux.
#
#   docker build -t imgsim .
#   docker run --rm imgsim                                   # run the test suite
#   docker run --rm -v "$PWD/models:/app/models" -v "$PWD/outputs:/app/outputs" imgsim \
#       python -m src.cli compare-models --reference models/a.glb --candidate models/b.glb --auto-orient
FROM python:3.11-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# CPU-only torch first: the default PyPI wheel pulls in ~2 GB of CUDA libraries.
RUN pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install -r requirements.txt

# Bake the LPIPS / AlexNet weights into the image so runs work offline.
RUN python -c "import lpips; lpips.LPIPS(net='alex')"

# Codex CLI (static musl binary, no Node.js needed) for command-runtime agent
# benchmarks (benchmarks/example/command_codex.json). Pin a stable release:
# alpha builds had a bug where `codex exec` did not register streamable-HTTP
# MCP tools (openai/codex#38689).
ARG CODEX_VERSION=0.160.0
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) cx=x86_64 ;; arm64) cx=aarch64 ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac; \
    curl -fsSL "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-${cx}-unknown-linux-musl.tar.gz" \
        -o /tmp/codex.tar.gz; \
    tar -xzf /tmp/codex.tar.gz -C /tmp; \
    install -m 0755 "/tmp/codex-${cx}-unknown-linux-musl" /usr/local/bin/codex; \
    rm -f /tmp/codex.tar.gz "/tmp/codex-${cx}-unknown-linux-musl"; \
    codex --version

COPY docker/benchmark/codex-entrypoint.sh /usr/local/bin/codex-entrypoint.sh
RUN chmod +x /usr/local/bin/codex-entrypoint.sh

COPY . .

# data/, models/ and outputs/ are meant to be bind-mounted from the host.
VOLUME ["/app/data", "/app/models", "/app/outputs"]

# Generates ~/.codex/config.toml from CODEX_*/MCP_URL env vars when absent.
ENTRYPOINT ["codex-entrypoint.sh"]
CMD ["python", "-m", "pytest", "tests", "-q"]
