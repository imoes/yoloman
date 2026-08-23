#!/usr/bin/env bash
# Build the agent binary + .deb, version-stamped from ./VERSION.
#
# The version is embedded in the binary (main.version, reported at startup and
# by GET /healthz) and set as the .deb package version, so every build is
# identifiable. Bump ./VERSION on every agent change.
#
# Output:
#   ./agentic-mcpd                       the static binary
#   ./deploy-artifacts/agent.deb         the .deb the UI Update button serves
#   ./deploy-artifacts/yoloman-agent_<ver>_amd64.deb  a versioned copy (+ .rpm)
#   ./deploy-artifacts/yoloman-agent-<ver>.manifest.json  version + sha256 of each
#     asset — what Bossman polls from the GitHub release to detect a new package.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
export VERSION
echo ">> building agent version ${VERSION}"

ROOT="$(pwd)"
# CGO_ENABLED=1: pulls in the real PAM authenticator (internal/authz/pam.go is
# //go:build cgo; the !cgo stub rejects every login). Needs gcc + libpam0g-dev
# at build time and libpam0g at runtime (a base package on Debian/RHEL). The
# binary is now dynamically linked (glibc + libpam) rather than fully static.
CGO_ENABLED=1 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o agentic-mcpd ./cmd/agentic-mcpd

mkdir -p deploy-artifacts
# The config templates the package carries: the reachable subset, not the whole tree. This also ASSERTS
# closure — if the index or the catalog names a template that is not on disk, the build stops here rather
# than shipping a console that offers a path it cannot serve. See the script's header for the measurement.
python3 scripts/stage-agent-templates.py

# nfpm resolves the config's relative src paths (../agentic-mcpd, ../configs/…)
# against the CWD, so run it from packaging/. Output to absolute paths. We build
# BOTH a .deb (Debian/Ubuntu) and a .rpm (RHEL/Fedora/SUSE) from the one config.
DEB="${ROOT}/deploy-artifacts/yoloman-agent_${VERSION}_amd64.deb"
RPM="${ROOT}/deploy-artifacts/yoloman-agent_${VERSION}_amd64.rpm"
( cd packaging && nfpm package -f nfpm.yaml -p deb -t "${DEB}" )
( cd packaging && nfpm package -f nfpm.yaml -p rpm -t "${RPM}" )
cp -f "${DEB}" "${ROOT}/deploy-artifacts/agent.deb"
cp -f "${RPM}" "${ROOT}/deploy-artifacts/agent.rpm"

# Release manifest: the small JSON Bossman polls from the GitHub release. It
# carries the version and the SHA-256 of each asset, so Bossman can detect a new
# package by HASH (and verify integrity before pushing a self-update) without
# downloading the whole package just to compare.
DEB_SHA="$(sha256sum "${DEB}" | awk '{print $1}')"
RPM_SHA="$(sha256sum "${RPM}" | awk '{print $1}')"
MANIFEST="${ROOT}/deploy-artifacts/yoloman-agent-${VERSION}.manifest.json"
cat > "${MANIFEST}" <<JSON
{
  "package": "yoloman-agent",
  "version": "${VERSION}",
  "deb": { "name": "yoloman-agent_${VERSION}_amd64.deb", "sha256": "${DEB_SHA}" },
  "rpm": { "name": "yoloman-agent_${VERSION}_amd64.rpm", "sha256": "${RPM_SHA}" }
}
JSON

echo ">> built:"
ls -la deploy-artifacts/*.deb deploy-artifacts/*.rpm "${MANIFEST}"
echo ">> deploy-artifacts/agent.deb (Debian) + agent.rpm (RHEL) are what the UI Update button serves."
echo ">> manifest: ${MANIFEST}"
