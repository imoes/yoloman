#!/usr/bin/env bash
# The in-container half of install-test-bossman.sh. Bash for /dev/tcp: neither base image ships curl, and the
# point of this test is the package rather than a reachable mirror.
set -u
fail() { echo "FAIL: $*" >&2; exit 1; }

eval "$INSTALL_CMD" >/tmp/install.log 2>&1 || { tail -20 /tmp/install.log; fail "install"; }
grep -q "needs a database before it can start" /tmp/install.log \
  || fail "the postinst did not say what is still missing (the database)"
echo "ok  installs and says the database is still missing"

getent passwd yoloman >/dev/null || fail "no yoloman service account"
[ -f /etc/yoloman/bossman.env ] || fail "no /etc/yoloman/bossman.env"
grep -q "^BOSSMAN_JWT_SECRET=..*" /etc/yoloman/bossman.env || fail "the postinst generated no session secret"
echo "ok  service account and a generated session secret"

# The bundled runtime, on a host with no python of its own. This is the whole reason the package is 100 MB.
command -v python3 >/dev/null && echo "    (note: this image has a python3 of its own: $(python3 -V 2>&1))"
/usr/share/yoloman-bossman/venv/bin/python -c 'import sys, fastapi, asyncpg; print("    bundled", sys.version.split()[0])' \
  || fail "the bundled runtime does not work here"
echo "ok  bundled runtime + dependencies"

sed -i "s|^BOSSMAN_DATABASE_URL=.*|BOSSMAN_DATABASE_URL=postgresql+asyncpg://bossman:testpw@${DB_HOST}:5432/${DB_NAME}|" \
  /etc/yoloman/bossman.env
bossman-migrate >/tmp/migrate.log 2>&1 || { tail -20 /tmp/migrate.log; fail "bossman-migrate"; }
grep -qE "Running upgrade|already at" /tmp/migrate.log || { tail -5 /tmp/migrate.log; fail "no migration ran"; }
echo "ok  bossman-migrate created the schema"

# THE FIRST-RUN FORM, proven where it matters: a migrated database with no account. Done BEFORE
# bossman-create-admin, because that is the only moment this state exists.
set -a; . /etc/yoloman/bossman.env; set +a
cd /usr/share/yoloman-bossman
/usr/share/yoloman-bossman/venv/bin/uvicorn bossman.main:app --host 127.0.0.1 --port "$BOSSMAN_PORT" \
  >/tmp/setup.log 2>&1 &
SETUP_APP=$!
setup_request() {   # defined early; the full request() below supersedes it
  local method=$1 path=$2 body=${3:-} out
  exec 3<>/dev/tcp/127.0.0.1/"$BOSSMAN_PORT" || return 1
  {
    printf '%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n' "$method" "$path"
    if [ -n "$body" ]; then
      printf 'Content-Type: application/json\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body"
    else
      printf '\r\n'
    fi
  } >&3
  out=$(cat <&3); exec 3<&-
  printf '%s\n%s\n' "$(printf '%s' "$out" | head -1 | awk '{print $2}')" \
                      "$(printf '%s' "$out" | sed -n '/^\r$/,$p' | tail -n +2)"
}
for _ in $(seq 1 90); do
  r=$(setup_request GET /healthz 2>/dev/null) && [ "$(printf '%s' "$r" | head -1)" = "200" ] && break
  sleep 1
done
state=$(setup_request GET /api/v1/auth/setup)
grep -q '"needs_setup":true' <<<"$(printf '%s' "$state" | tail -n +2)" \
  || { printf '%s' "$state" | head -c 200; fail "a migrated, accountless database does not report needs_setup"; }
echo "ok  a fresh installation reports that it needs setup"
created=$(setup_request POST /api/v1/auth/setup '{"username":"chief","password":"a-long-enough-pw"}')
[ "$(printf '%s' "$created" | head -1)" = "200" ] \
  || { printf '%s' "$created" | head -c 300; fail "the setup form could not create the first administrator"; }
grep -q 'access_token' <<<"$(printf '%s' "$created" | tail -n +2)" \
  || fail "setup returned no token — the operator would have to log in again"
echo "ok  the setup form created the first administrator and signed them in"
again=$(setup_request POST /api/v1/auth/setup '{"username":"sneak","password":"another-long-pw"}')
[ "$(printf '%s' "$again" | head -1)" = "409" ] \
  || fail "setup is still open after an account exists (got $(printf '%s' "$again" | head -1))"
echo "ok  setup closed behind itself (409)"
short=$(setup_request GET /api/v1/auth/setup)
grep -q '"needs_setup":false' <<<"$(printf '%s' "$short" | tail -n +2)" || fail "needs_setup did not flip"
kill $SETUP_APP 2>/dev/null; wait $SETUP_APP 2>/dev/null

bossman-create-admin operator testpassword >/tmp/admin.log 2>&1 \
  || { tail -20 /tmp/admin.log; fail "bossman-create-admin"; }
echo "ok  bossman-create-admin still works for a scripted install"

# The unit's own ExecStart, run by hand: there is no systemd in a container, and the command line is the part
# worth testing anyway.
set -a; . /etc/yoloman/bossman.env; set +a
cd /usr/share/yoloman-bossman
/usr/share/yoloman-bossman/venv/bin/uvicorn bossman.main:app --host 127.0.0.1 --port "$BOSSMAN_PORT" \
  >/tmp/app.log 2>&1 &
APP=$!

request() {
  local method=$1 path=$2 body=${3:-} out status
  exec 3<>/dev/tcp/127.0.0.1/"$BOSSMAN_PORT" || return 1
  {
    printf '%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n' "$method" "$path"
    if [ -n "$body" ]; then
      printf 'Content-Type: application/json\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body"
    else
      printf '\r\n'
    fi
  } >&3
  out=$(cat <&3); exec 3<&-
  status=$(printf '%s' "$out" | head -1 | awk '{print $2}')
  printf '%s\n%s\n' "$status" "$(printf '%s' "$out" | sed -n '/^\r$/,$p' | tail -n +2)"
}
status_of() { printf '%s' "$1" | head -1; }
body_of() { printf '%s' "$1" | tail -n +2; }

for _ in $(seq 1 90); do
  r=$(request GET /healthz 2>/dev/null) && [ "$(status_of "$r")" = "200" ] && break
  sleep 1
done
[ "$(status_of "$r")" = "200" ] || { tail -25 /tmp/app.log; fail "the app did not answer /healthz"; }
echo "ok  the app started and answers /healthz"

login=$(request POST /api/v1/auth/login '{"username":"operator","password":"testpassword"}')
[ "$(status_of "$login")" = "200" ] || { body_of "$login" | head -c 300; fail "the created operator cannot log in"; }
echo "ok  the created operator logs in"

# THE difference from the Docker deployment: no nginx, so this process must serve the console itself.
ui=$(request GET /)
[ "$(status_of "$ui")" = "200" ] || fail "the web console is not served (status $(status_of "$ui"))"
grep -qi "<app-root\|bossman" <<<"$(body_of "$ui")" || fail "GET / did not return the console's index.html"
echo "ok  the web console is served by the same process"
# The SPA fallback, which is what a deep link needs to survive a reload.
deep=$(request GET /hosts/some-id)
[ "$(status_of "$deep")" = "200" ] || fail "a deep link 404s — the SPA fallback is not active"
echo "ok  a deep link falls back to index.html"
# And it must NOT swallow the API: the mount is last for exactly this reason.
missing=$(request GET /api/v1/definitely-not-a-route)
[ "$(status_of "$missing")" = "404" ] || fail "the UI mount swallowed an unknown API path (got $(status_of "$missing"))"
echo "ok  the UI mount does not shadow /api/v1"

kill $APP 2>/dev/null
echo "ALL OK"
