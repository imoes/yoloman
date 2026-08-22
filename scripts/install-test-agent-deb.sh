#!/usr/bin/env bash
# Install the built .deb on a real Debian and the .rpm on a real EL, and check what the INSTALL claims.
#
# Every piece of the standalone catch-up has its own test; none of them proves the PACKAGE. This does, by
# asking the installed system rather than the repo:
#   - the postinst created group yoloadmin, empty
#   - the projections the field editor serves are actually installed (a missing one silently disables the
#     Configure button, and the endpoint's own reason text is the only clue)
#   - the daemon starts and /api/v1/auth/methods advertises the login it can really perform
#   - a real login works: root without the group, a yoloadmin member, and a non-member refused
#
# The container has no systemd, so the daemon is started directly — that isolates the package's contents
# from the unit file, which is tested by installing on a real host.
set -euo pipefail
cd "$(dirname "$0")/.."
DEB=${DEB:-deploy-artifacts/agent.deb}
RPM=${RPM:-deploy-artifacts/agent.rpm}
[ -f "$DEB" ] || { echo "no $DEB — run scripts/build-agent-deb.sh first"; exit 1; }

# dpkg/rpm rather than apt/dnf, and mounted WITH its extension: apt refuses "Unsupported file /pkg" on a
# name it cannot classify, and both resolvers want the network for a dependency that is already installed
# (libpam0g and libpam-modules are in the debian:12 base image, pam in almalinux:9). Installing offline also
# makes this test about the package rather than about a mirror being reachable — the first run failed on
# deb.debian.org, which says nothing about the .deb.
run() { # run <image> <install-cmd> <package-file> <extension>
  local image=$1 install=$2 pkg=$3 ext=$4
  echo; echo "===== $image ====="
  docker run --rm -v "$PWD/$pkg":/pkg.$ext:ro -v "$PWD/scripts/install-test-agent-body.sh":/body.sh:ro \
    -e INSTALL_CMD="$install" -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
    "$image" bash /body.sh
}
run debian:12   "dpkg -i /pkg.deb"    "$DEB" deb
run almalinux:9 "rpm -Uvh /pkg.rpm"   "$RPM" rpm
