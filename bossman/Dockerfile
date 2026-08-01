FROM python:3.12-slim AS base

# BuildKit does not forward the host's proxy env vars into RUN steps by
# default (only into its own registry pulls) — a network that needs one
# passes it via build.args in docker-compose.override.yml, so it must be
# declared explicitly here to be received at all.
ARG http_proxy
ARG https_proxy
ARG no_proxy
ENV http_proxy=$http_proxy https_proxy=$https_proxy no_proxy=$no_proxy

# The docker CLI so Bossman can drive the PXE nested-virt lab via `docker exec <pxe> vm-control.sh`
# (services/vm_lab.py). Only used when BOSSMAN_PXE_CONTAINER is set and the docker socket is mounted;
# harmless otherwise. docker-cli only (no daemon) — it talks to the host's socket.
RUN apt-get update && apt-get install -y --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*

# Copied from the official uv image rather than `pip install uv` — avoids
# a pypi.org round trip during the build (unreliable/slow in some Docker
# build-network setups even when the host itself reaches pypi.org fine).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY bossman ./bossman
COPY alembic ./alembic
COPY alembic.ini ./
COPY scripts ./scripts

# Bossman's own mTLS client keypair (services/keys.py) and the plans
# directory both need a writable/readable location — /etc/bossman isn't
# writable by a non-root container user, so both default paths are
# overridden (see docker-compose.yml) to point here instead.
RUN mkdir -p /app/data/tls

# `python scripts/seed_admin.py` (a plain script-file invocation, unlike
# `-c` or a console-script entry point such as `alembic`) puts the
# script's own directory on sys.path[0], not /app — found the hard way,
# `import bossman` failed even under `uv run` for exactly this invocation
# form, while `uv run alembic upgrade head` worked (alembic's own CLI adds
# the CWD to sys.path itself). PYTHONPATH=/app makes every invocation
# style import bossman correctly, regardless of how it's run.
ENV PYTHONPATH=/app

EXPOSE 8000

CMD ["uv", "run", "uvicorn", "bossman.main:app", "--host", "0.0.0.0", "--port", "8000"]
