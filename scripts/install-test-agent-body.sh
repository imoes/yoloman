#!/usr/bin/env bash
# The in-container half of install-test-agent-deb.sh. A separate file because a heredoc inside a heredoc
# terminates the wrong one — that is how a driver in this repo got mangled once already.
#
# BASH, and HTTP over /dev/tcp, because neither debian:12 nor almalinux:9 ships curl or wget and there is no
# network to install one: the point of this test is the package, not a reachable mirror. Bash is in both
# images, and /dev/tcp needs nothing at all.
set -u
fail() { echo "FAIL: $*" >&2; exit 1; }

eval "$INSTALL_CMD" >/tmp/install.log 2>&1 || { tail -20 /tmp/install.log; fail "install"; }
grep -i "yoloadmin" /tmp/install.log || fail "the install said nothing about the login group"

getent group yoloadmin >/dev/null || fail "postinst did not create group yoloadmin"
[ -z "$(getent group yoloadmin | cut -d: -f4)" ] || fail "the group was created with members in it"
echo "ok  group yoloadmin exists and is empty"

# The projections the standalone field editor serves. Absence is silent in the UI, so it is loud here.
for f in config_template_index.json config_directive_keys.json template_withheld.json \
         config_generated.json template_unsettable.json template_renderer_gaps.json \
         config_path_verdicts.json codec_probe_verdicts.json config_unowned_paths.json \
         config_codecs.json config_directives.json; do
  [ -s "/usr/share/agentic-mcp/configs/$f" ] || fail "missing /usr/share/agentic-mcp/configs/$f"
done
echo "ok  all eleven catalog/projection files installed"
[ -d /usr/share/agentic-mcp/configs/config_templates ] || fail "the template tree is missing"

# A member and a non-member with the SAME password, plus root — so the group is what makes the difference.
useradd -m tester; useradd -m outsider
echo "tester:geheim123" | chpasswd; echo "outsider:geheim123" | chpasswd; echo "root:rootpw123" | chpasswd
gpasswd -a tester yoloadmin >/dev/null

TOKEN=$(sed -n 's/^token: "\(.*\)"$/\1/p' /etc/agentic-mcp/config.yaml)
[ -n "$TOKEN" ] || fail "postinst did not generate a bearer token"
# THE NEW NAME, and then the old one as a symlink: a fleet's runbooks and Bossman's own self-update invoke
# /usr/bin/agentic-mcpd, so the rename must not break them.
[ -x /usr/bin/yoloman-agent ] || fail "the binary is not installed as /usr/bin/yoloman-agent"
[ -L /usr/bin/agentic-mcpd ] || fail "the compatibility symlink /usr/bin/agentic-mcpd is missing"
[ "$(readlink /usr/bin/agentic-mcpd)" = "/usr/bin/yoloman-agent" ] \
  || fail "the symlink points at $(readlink /usr/bin/agentic-mcpd)"
/usr/bin/agentic-mcpd --version >/dev/null 2>&1 || fail "the old name no longer runs"
echo "ok  installed as yoloman-agent, reachable as agentic-mcpd"
[ -f /usr/lib/systemd/system/yoloman-agent.service ] || fail "no yoloman-agent.service"
grep -q "^Alias=agentic-mcp.service" /usr/lib/systemd/system/yoloman-agent.service \
  || fail "the unit does not alias the old name"
echo "ok  unit yoloman-agent.service, aliasing agentic-mcp.service"

/usr/bin/yoloman-agent --config /etc/agentic-mcp/config.yaml >/tmp/daemon.log 2>&1 &
DAEMON=$!

# request METHOD PATH [JSON-BODY] [AUTH-HEADER-VALUE] -> "<status>\n<body>"
request() {
  local method=$1 path=$2 body=${3:-} auth=${4:-} line status out
  exec 3<>/dev/tcp/127.0.0.1/8010 || return 1
  {
    printf '%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n' "$method" "$path"
    [ -n "$auth" ] && printf 'Authorization: %s\r\n' "$auth"
    if [ -n "$body" ]; then
      printf 'Content-Type: application/json\r\nContent-Length: %d\r\n\r\n%s' "${#body}" "$body"
    else
      printf '\r\n'
    fi
  } >&3
  out=$(cat <&3)
  exec 3<&-
  status=$(printf '%s' "$out" | head -1 | awk '{print $2}')
  printf '%s\n%s\n' "$status" "$(printf '%s' "$out" | sed -n '/^\r$/,$p' | tail -n +2)"
}
status_of() { printf '%s' "$1" | head -1; }
body_of() { printf '%s' "$1" | tail -n +2; }

# Silent while waiting: the first attempts land before the listener is up, and "Connection refused" twice is
# the normal path, not a finding.
for _ in $(seq 1 60); do
  r=$(request GET /healthz 2>/dev/null) && [ "$(status_of "$r")" = "200" ] && break
  sleep 0.25
done
[ "$(status_of "$r")" = "200" ] || { tail -20 /tmp/daemon.log; fail "daemon did not answer /healthz"; }
echo "ok  daemon started ($(body_of "$r" | head -c 120))"

methods=$(body_of "$(request GET /api/v1/auth/methods)")
echo "    /auth/methods -> $methods"
grep -q '"password":true' <<<"$methods" || fail "the installed agent reports no password login"
grep -q '"group":"yoloadmin"' <<<"$methods" || fail "/auth/methods does not name the required group"
grep -q '"superuser_exempt":true' <<<"$methods" || fail "/auth/methods does not state the root exemption"

login() {
  status_of "$(request POST /api/v1/auth/login "{\"username\":\"$1\",\"password\":\"$2\"}")"
}
[ "$(login root rootpw123)" = "200" ] || fail "root could not log in (the group is empty!)"
echo "ok  root logs in without being in the group"
[ "$(login tester geheim123)" = "200" ] || fail "a yoloadmin member could not log in"
echo "ok  a yoloadmin member logs in"
[ "$(login outsider geheim123)" = "401" ] || fail "a non-member logged in"
echo "ok  a non-member with the same password is refused"
[ "$(login tester falsch)" = "401" ] || fail "a wrong password logged in"
echo "ok  a member's wrong password is refused"

# The surface this session added, asked of the INSTALLED catalog rather than the repo.
fields=$(body_of "$(request GET "/api/v1/config-fields?path=/etc/ssh/sshd_config" "" "Bearer $TOKEN")")
grep -q '"write":"codec"' <<<"$fields" || { head -c 300 <<<"$fields"; fail "config-fields lost sshd_config"; }
echo "ok  config-fields answers from the installed catalog ($(grep -o '"format":"[a-z_]*"' <<<"$fields"))"
idx=$(body_of "$(request GET /api/v1/config-templates/index "" "Bearer $TOKEN")")
grep -q '"available":true' <<<"$idx" || fail "the template index is not available"
# The FIRST "family" in the reply, not the last: index entries carry a family of their own (the -redhat
# templates), and a greedy match reported "redhat" on debian:12 — a wrong answer about the host, produced by
# the test rather than by the agent. Go sorts map keys, so the top-level one comes before "paths".
echo "ok  config-templates/index available (family: $(grep -o '"family":"[a-z]*"' <<<"$idx" | head -1))"
# The two guards, asked of the INSTALLED records. /etc/aide is a directory in its package and no harvested
# package ships a file there, so the editor must warn. /etc/hostname belongs to no package on any
# distribution because the system creates it — warning about that would be a false statement about the
# machine's own hostname, and it is the case the guard was built for.
aide=$(body_of "$(request GET "/api/v1/config-fields?path=/etc/aide" "" "Bearer $TOKEN")")
grep -q '"path_verdict"' <<<"$aide" || fail "no path_verdict for /etc/aide — the phantom-path guard is not shipped"
echo "ok  a path no package ships carries its verdict"
host=$(body_of "$(request GET "/api/v1/config-fields?path=/etc/hostname" "" "Bearer $TOKEN")")
if grep -q '"path_verdict"' <<<"$host"; then
  head -c 300 <<<"$host"; fail "/etc/hostname was reported as a nonexistent file"
fi
echo "ok  a system-created file is NOT reported as missing"

gen=$(body_of "$(request GET /api/v1/config-generated "" "Bearer $TOKEN")")
grep -q '"count":[1-9]' <<<"$gen" || fail "config-generated reports nothing"
echo "ok  config-generated reports $(sed -n 's/.*"count":\([0-9]*\).*/\1/p' <<<"$gen") machine-written files"

kill $DAEMON 2>/dev/null
echo "ALL OK"
