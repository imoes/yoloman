#!/usr/bin/env bash
# Prove the standalone login on a REAL distro, not against a fake helper.
#
# The unit tests in internal/authz use a stub that speaks the protocol I measured. This runs the CGO-free
# build — the one that has no PAM at all and must fall back to unix_chkpwd — against a real /etc/shadow entry
# and a real group, in debian:12 and almalinux:9. It also runs the package's postinst group snippet, because
# "the group is created at install time" is a claim about groupadd on two distros, not about Go.
#
#   scripts/test-standalone-login.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp -d)/authz.test
CGO_ENABLED=0 go test -c -o "$BIN" ./internal/authz/
echo ">> built the CGO-free test binary (no PAM linked: $(readelf -d "$BIN" 2>/dev/null | grep -c libpam || true) libpam refs)"

for image in debian:12 almalinux:9; do
  echo; echo "===== $image ====="
  docker run --rm -v "$BIN":/authz.test:ro -v "$PWD/packaging/postinst":/postinst:ro "$image" sh -c '
    set -e
    # The install-time step, verbatim from the package: create the group, empty.
    CONF_DIR=/etc/agentic-mcp; mkdir -p "$CONF_DIR"
    sed -n "/^LOGIN_GROUP=/,/^fi$/p" /postinst > /tmp/group.sh
    sh /tmp/group.sh
    getent group yoloadmin || { echo "FAIL: postinst did not create the group"; exit 1; }
    # A member and a non-member, both with the same password — so the group is what makes the difference.
    useradd -m tester 2>/dev/null || adduser -D tester
    useradd -m outsider 2>/dev/null || adduser -D outsider
    echo "tester:geheim123" | chpasswd
    echo "outsider:geheim123" | chpasswd
    gpasswd -a tester yoloadmin >/dev/null 2>&1 || usermod -aG yoloadmin tester
    ls -l /usr/sbin/unix_chkpwd
    AUTHZ_REAL_USER=tester AUTHZ_REAL_PASSWORD=geheim123 \
      AUTHZ_REAL_GROUP=yoloadmin AUTHZ_REAL_NONMEMBER=outsider \
      /authz.test -test.v -test.run "Chkpwd|GroupRequired" 2>&1 | tail -30
  '
done
