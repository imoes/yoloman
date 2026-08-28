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
# harmless otherwise. `docker-cli` is the client only (no daemon) — it provides /usr/bin/docker and
# talks to the host's socket. (docker.io's CLI lives in this separate package, which --no-install-
# recommends would otherwise skip, leaving docker.io "installed" but no /usr/bin/docker.)
RUN apt-get update && apt-get install -y --no-install-recommends docker-cli \
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

# The gonja render-check binary (enum-enrich gate for the on-demand qualify
# endpoint) is INSTALLED into the image — not mounted — so a qualify run in the
# container needs no `go`. RENDER_CHECK_BIN makes enrich_gates use it directly.
COPY bin/render-check /usr/local/bin/render-check
RUN chmod +x /usr/local/bin/render-check
ENV RENDER_CHECK_BIN=/usr/local/bin/render-check

# Bossman's own mTLS client keypair (services/keys.py) and the plans
# directory both need a writable/readable location — /etc/bossman isn't
# writable by a non-root container user, so both default paths are
# overridden (see docker-compose.yml) to point here instead.
RUN mkdir -p /app/data/tls

# `python scripts/seed_admin.py` (a plain script-file invocation, unlike `-c` or a console-script entry
# point such as `alembic`) put the script's own directory on sys.path[0], not /app — found the hard way,
# `import bossman` failed even under `uv run` for exactly that form. The seed now runs as
# `-m bossman.tools.seed_admin`, which has no such problem; PYTHONPATH=/app is kept because it makes every
# other invocation style import bossman correctly too.
ENV PYTHONPATH=/app

EXPOSE 8000

CMD ["uv", "run", "uvicorn", "bossman.main:app", "--host", "0.0.0.0", "--port", "8000"]
