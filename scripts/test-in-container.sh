#!/usr/bin/env bash
# Run the Bossman test suite where the database actually is: inside the compose network.
#
# WHY THIS SCRIPT EXISTS
#
# 1. The host cannot reach the compose Postgres. There is exactly ONE database (the test
#    system in docker compose; no dev DB), and it is not published to the host in a form
#    the suite's settings resolve. So ~16 DB-backed end-to-end tests ("real HTTP, real
#    Postgres") fail from the host with ConnectionRefusedError and get mentally filed as
#    "always red" — which is how a real failure hid in there for a while (an OpenRouter
#    backend reporting the wrong identity; see docs/logik-audit.md, area 9).
#
# 2. `uv run` is mandatory; do NOT call /app/.venv/bin/python directly. The service's
#    PID 1 is `uv run uvicorn …`, i.e. the venv is synced by uv at start. A fresh
#    container's baked venv is incomplete: calling its python directly failed first with
#    "No module named pytest" and then, in another attempt, with "No module named
#    jinja2" — both look like broken code and are neither.
#
# 3. pytest lives in the `dev` dependency group, which the image deliberately omits
#    (`uv sync --frozen --no-dev` in the Dockerfile). It is installed here at run time.
#    Do not "fix" this by installing pytest into the running container: that is lost on
#    the next `up --build` and hides image drift.
#
# 4. TWO RUNS MUST NOT OVERLAP — this is measured, not theoretical. tests/conftest.py's
#    autouse `_drop_test_residue` fixture deletes every test-shaped row created after ITS
#    OWN start time, across a database it shares with the running system. That criterion
#    has no notion of ownership, so a second test process's rows match it too. Proof: the
#    same three files pass alone but produce 10 and 12 failures when two runs are started
#    at the same time. Hence the lock below. The deeper fix is to make the cleanup delete
#    only what its own process created (see the finding in docs/logik-audit.md, area 9).
#
# Usage:
#   scripts/test-in-container.sh                 # whole suite
#   scripts/test-in-container.sh tests/test_x.py # a subset (paths relative to bossman/)
#   scripts/test-in-container.sh -k pattern      # any pytest arguments
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT=agentic-mcp
LOCK=/tmp/bossman-test-in-container.lock

# Three suites need a network/LLM backend the container has no business reaching; they
# are excluded so a red result always means "the code is wrong", never "the batch host
# is down". Remove an --ignore when you actually want to exercise that path.
IGNORES=(
  --ignore=/app/tests/test_batch_verify.py
  --ignore=/app/tests/test_enrich_gates.py
  --ignore=/app/tests/test_qualify_enrich.py
)

if [ "$#" -gt 0 ]; then
  # Caller named targets: pass them through verbatim, mapped into the container.
  ARGS=("$@")
  ARGS=("${ARGS[@]//tests\//\/app\/tests\/}")
else
  ARGS=(/app/tests "${IGNORES[@]}")
fi

echo "→ waiting for the test lock ($LOCK) so no two runs share the database…"
exec 9>"$LOCK"
flock 9

# The lock alone is not enough, and that was measured: a run killed by `timeout` leaves its
# CONTAINER alive (the signal reaches the compose CLI, not the container), the lock is released
# with the dead CLI, and the orphan keeps running teardowns that delete the next run's rows —
# 15 minutes after being "stopped" one was still sabotaging results. So the container gets a
# fixed name, any leftover is removed before starting, and it is removed again on exit however
# this script ends.
CONTAINER=bossman-tests
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo "→ running pytest inside the compose network (project $PROJECT)"
docker compose -p "$PROJECT" run --rm --no-deps --name "$CONTAINER" \
  -v "$PWD/bossman/tests:/app/tests:ro" -w /app bossman \
  sh -c "uv sync --frozen >/dev/null 2>&1 && uv run pytest -q ${ARGS[*]}"
