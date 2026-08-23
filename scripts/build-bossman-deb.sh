#!/usr/bin/env bash
# Build the Bossman .deb and .rpm — a self-contained native install of the fleet controller.
#
# DOCKER REMAINS THE PRIMARY DEPLOYMENT (docker-compose.yml). This exists for a host where a container
# runtime is not wanted, and it makes exactly one promise less than compose does: Postgres is a REQUIREMENT,
# not something the package installs. Everything else — the Python runtime, every dependency, the web console
# and the config catalog — is inside the package.
#
# WHY A BUNDLED INTERPRETER, and not a dependency on the distro's python3. bossman needs >= 3.12; Debian 12
# ships 3.11 and EL 9 ships 3.9. Depending on the system Python would make the package uninstallable on both
# of the distributions it is meant for. So `uv` fetches a standalone CPython and it is shipped in the tree.
# The package is ~150 MB and installs on anything with glibc >= 2.28, which is the trade this buys.
#
# WHY THE BUILD RUNS IN A CONTAINER. A virtualenv records the absolute path it was created at. Building it at
# /opt/yoloman-bossman/venv on the build host would mean writing outside the repo as root; building it
# somewhere else and moving it leaves every script's shebang pointing at a path that does not exist on the
# target. In a container the final path IS available, so the venv is created where it will live and copied
# out afterwards. (uv's --relocatable would also work for the shebangs, but not for the interpreter's own
# sysconfig paths.)
#
#   scripts/build-bossman-deb.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="$(cat VERSION)"
export VERSION
echo ">> building yoloman-bossman ${VERSION}"

STAGE="$ROOT/deploy-artifacts/bossman-stage"
# A leftover stage from a build that failed BEFORE the chown below cannot be removed as this user, so the
# removal is done with the same privileges that created it.
if [ -d "$STAGE" ] && ! rm -rf "$STAGE" 2>/dev/null; then
  docker run --rm -v "$ROOT/deploy-artifacts":/out debian:12 rm -rf /out/bossman-stage
fi
mkdir -p "$STAGE/opt/yoloman-bossman"
SHARE="$STAGE/opt/yoloman-bossman"

# ── 1. the web console ──────────────────────────────────────────────────────────────────────────────────
# Built here rather than taken from a previous run: a package that ships whatever happened to be in dist/
# is a package whose contents nobody can reproduce.
echo ">> building the web console"
( cd bossman-ui && npx ng build --configuration production >/dev/null )
cp -r bossman-ui/dist/bossman-ui/browser "$SHARE/ui"

# ── 2. the application ──────────────────────────────────────────────────────────────────────────────────
echo ">> assembling the application"
# bossman/scripts is local operating equipment and not in the repository; the eight scripts the
# product actually runs live in bossman/bossman/tools and come along with the package.
cp -r bossman/bossman bossman/alembic "$SHARE/"
# NO __pycache__. A compiled cache is stale by construction — and it leaked the source it was compiled FROM:
# a .pyc built before the infrastructure names were removed still carried one of them into the package, which
# is how this line came to exist. Interpreter caches are not build output.
find "$SHARE" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$SHARE" -name "*.pyc" -delete 2>/dev/null || true
cp bossman/alembic.ini bossman/pyproject.toml bossman/uv.lock "$SHARE/"
# The render-check binary (the enum-enrich gate for the on-demand qualify endpoint), same as the image.
install -Dm755 bossman/bin/render-check "$SHARE/bin/render-check"
install -Dm755 packaging/bossman/bin/bossman-migrate "$SHARE/bin/bossman-migrate"
install -Dm755 packaging/bossman/bin/bossman-create-admin "$SHARE/bin/bossman-create-admin"

# The config catalog. The same files the Docker deployment bind-mounts, and the same ones the agent package
# ships — one catalog, three ways of reaching it.
mkdir -p "$SHARE/configs"
for f in package_catalog.json config_codecs.json config_directives.json config_generated.json \
         config_path_verdicts.json codec_probe_verdicts.json config_unowned_paths.json \
         config_template_index.json config_directive_keys.json template_withheld.json \
         template_unsettable.json template_renderer_gaps.json package_services.json \
         package_doc_audit.json package_names_el.json; do
  [ -f "configs/$f" ] && cp "configs/$f" "$SHARE/configs/$f"
done
cp -r configs/config_templates "$SHARE/configs/config_templates"
cp -r bossman/plans "$SHARE/plans-default" 2>/dev/null || true

# ── 3. the runtime ──────────────────────────────────────────────────────────────────────────────────────
# In a debian:12 container, at the path the package installs to. bookworm's glibc 2.36 is not the constraint
# — the bundled CPython is a manylinux build — but building on the older base keeps the render-check binary
# and any wheel with a C extension usable on both target families.
echo ">> building the bundled runtime (container)"
docker run --rm \
  -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" -e no_proxy="${no_proxy:-}" \
  -v "$SHARE":/build:rw \
  -v "$ROOT/bossman/pyproject.toml":/src/pyproject.toml:ro \
  -v "$ROOT/bossman/uv.lock":/src/uv.lock:ro \
  -e BUILD_UID="$(id -u)" -e BUILD_GID="$(id -g)" \
  --entrypoint sh ghcr.io/astral-sh/uv:debian-slim -c '
    set -e
    mkdir -p /opt/yoloman-bossman
    cp /src/pyproject.toml /src/uv.lock /opt/yoloman-bossman/
    cd /opt/yoloman-bossman
    # only-managed: never link the container'"'"'s own python, or the venv would point at an interpreter the
    # target host does not have.
    export UV_PYTHON_INSTALL_DIR=/opt/yoloman-bossman/python
    uv python install --python-preference only-managed 3.12
    uv venv --python-preference only-managed --python 3.12 /opt/yoloman-bossman/venv
    VIRTUAL_ENV=/opt/yoloman-bossman/venv uv sync --frozen --no-dev --active
    # Copy the result out, INCLUDING the interpreter the venv points at.
    cp -a /opt/yoloman-bossman/venv /build/venv
    cp -a /opt/yoloman-bossman/python /build/python
    # HANDED BACK TO THE CALLER. Files the container writes are root-owned, and the next build could then
    # not even delete its own staging directory ("rm: Keine Berechtigung" on a few thousand files).
    chown -R "$BUILD_UID:$BUILD_GID" /build
  '
# VERIFIED WHERE IT WILL LIVE. venv/bin/python is a symlink to the bundled interpreter's ABSOLUTE path, so
# running it from the staging directory fails by design — that path only exists once installed. The check
# therefore mounts the tree at the final prefix, which is exactly what the target does, in an image that has
# no python of its own so nothing else can answer.
docker run --rm -v "$SHARE":/opt/yoloman-bossman:ro debian:12 \
  /opt/yoloman-bossman/venv/bin/python -c \
  'import sys, fastapi, asyncpg, sqlalchemy, alembic; print(">> bundled python", sys.version.split()[0], "— deps import cleanly")' \
  || { echo "the bundled runtime does not work at its installed path — build aborted" >&2; exit 1; }

# ── 4. the packages ─────────────────────────────────────────────────────────────────────────────────────
mkdir -p deploy-artifacts
DEB="$ROOT/deploy-artifacts/yoloman-bossman_${VERSION}_amd64.deb"
RPM="$ROOT/deploy-artifacts/yoloman-bossman_${VERSION}_amd64.rpm"
# The resolved config, written beside the staging tree. nfpm expands ${VERSION} itself but not the paths in
# `contents.src`, so those are substituted here — with python rather than envsubst, which is not installed
# everywhere and would silently eat every other $ in the file.
NFPM="$ROOT/deploy-artifacts/bossman-nfpm.yaml"
STAGE="$STAGE" PKGDIR="$ROOT/packaging/bossman" python3 - "$ROOT/packaging/bossman/nfpm.yaml" "$NFPM" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
for key in ("STAGE", "PKGDIR"):
    text = text.replace("${%s}" % key, os.environ[key])
open(dst, "w").write(text)
PY
nfpm package -f "$NFPM" -p deb -t "$DEB"
nfpm package -f "$NFPM" -p rpm -t "$RPM"
cp "$DEB" "$ROOT/deploy-artifacts/bossman.deb"
cp "$RPM" "$ROOT/deploy-artifacts/bossman.rpm"

ls -la "$DEB" "$RPM"
echo ">> deploy-artifacts/bossman.deb + bossman.rpm"
