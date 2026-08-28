#!/usr/bin/env bash
# Install the Bossman package on a real Debian and a real EL, with a real Postgres, and prove it serves.
#
# "It installs" is not the claim that matters. The claims are: the bundled runtime works on a host that has
# no Python of its own, the migration creates a schema, the first operator can be created, the unit's command
# line starts the app, and the web console is served by that same process — because the native install has no
# nginx and that is the one difference from the Docker deployment.
#
# Postgres runs as a sibling container rather than being installed in the same one, and it is the SAME image
# the compose deployment uses: the schema needs BOTH extensions — timescaledb (hypertables and continuous
# aggregates for the metric store) and pgvector (chunk embeddings). Found by running this test against a
# pgvector-only image, which failed at `CREATE EXTENSION timescaledb`. A test that quietly used a different
# database than the product would prove the wrong thing.
set -euo pipefail
cd "$(dirname "$0")/.."
DEB=${DEB:-deploy-artifacts/bossman.deb}
RPM=${RPM:-deploy-artifacts/bossman.rpm}
[ -f "$DEB" ] || { echo "no $DEB — run scripts/build-bossman-deb.sh first"; exit 1; }

NET=bossman-installtest
DBS=""
cleanup() {
  for db in $DBS; do docker rm -f "$db" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker rm -f bossman-installtest-deb bossman-installtest-rpm >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null

# ONE POSTGRES PER RUN, not one instance with two databases. Sharing the instance produced "tuple
# concurrently deleted" while dropping a continuous aggregate — timescaledb's background workers are
# per-INSTANCE, so two migrations racing in one server is a flake in the test rather than a defect in the
# package. Separate servers cannot race.
start_db() { # start_db <name>
  local name=$1
  docker run -d --name "$name" --network "$NET" \
    -e POSTGRES_USER=bossman -e POSTGRES_PASSWORD=testpw -e POSTGRES_DB=bossman \
    timescale/timescaledb:latest-pg16 >/dev/null
  DBS="$DBS $name"
  for _ in $(seq 1 60); do
    docker exec "$name" pg_isready -U bossman >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "postgres $name did not become ready" >&2
  exit 1
}

run() { # run <image> <install-cmd> <package-file> <extension> <db-container> <reinstall-cmd>
  local image=$1 install=$2 pkg=$3 ext=$4 db=$5 reinstall=$6
  echo; echo "===== $image ====="
  start_db "$db"
  docker run --rm --network "$NET" \
    -v "$PWD/$pkg":/pkg.$ext:ro -v "$PWD/scripts/install-test-bossman-body.sh":/body.sh:ro \
    -e INSTALL_CMD="$install" -e REINSTALL_CMD="$reinstall" -e DB_HOST="$db" -e DB_NAME=bossman \
    "$image" bash /body.sh
}

run debian:12   "dpkg -i /pkg.deb"  "$DEB" deb bossman-installtest-deb "dpkg -i /pkg.deb"
run almalinux:9 "rpm -Uvh /pkg.rpm" "$RPM" rpm bossman-installtest-rpm "rpm -Uvh --replacepkgs /pkg.rpm"
