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
# scx schedulers (scripts/build-scx.sh) for yoloman.scx_install's bundled source: stage the default version's
# build when there is one. Without it the package carries only the README and scx_install builds from upstream.
SCX_VERSION="$(sed -n 's/^_DEFAULT_VERSION = "\(v[0-9.]*\)"$/\1/p' internal/starmodules/embedded/modules/yoloman/scx_install.star)"
rm -rf packaging/stage/scx && mkdir -p packaging/stage/scx
if [ -f "deploy-artifacts/scx/${SCX_VERSION}/BUILD-INFO" ]; then
    cp -a "deploy-artifacts/scx/${SCX_VERSION}" "packaging/stage/scx/${SCX_VERSION}"
    echo ">> bundling scx ${SCX_VERSION}: $(cd "packaging/stage/scx/${SCX_VERSION}" && ls scx_* | tr '\n' ' ')"
else
    echo ">> no scx ${SCX_VERSION} build in deploy-artifacts/scx (scripts/build-scx.sh) — the package carries none"
fi
printf '%s\n' "scx schedulers bundled with yoloman-agent for yoloman.scx_install (source=bundled)." \
    "Built by scripts/build-scx.sh; each version directory holds BUILD-INFO with commit, rustc and glibc ceiling." \
    > packaging/stage/scx/README
# The config templates the package carries: the reachable subset, not the whole tree. This also ASSERTS
# closure — if the index or the catalog names a template that is not on disk, the build stops here rather
# than shipping a console that offers a path it cannot serve. See the script's header for the measurement.
python3 scripts/stage-agent-templates.py

# nfpm resolves the config's relative src paths (../agentic-mcpd, ../configs/…)
# against the CWD, so run it from packaging/. Output to absolute paths. We build
# BOTH a .deb (Debian/Ubuntu) and a .rpm (RHEL/Fedora/SUSE) from the one config.
# nfpm stamps the build machine's hostname into every RPM header (BUILDHOST). Measured 2026-10-19: every public
# RPM up to 0.57.73 carried this machine's internal FQDN. RPMs are therefore built in an unprivileged UTS namespace
# with a neutral name (no root needed); RPM_BUILDHOST overrides it.
rpm_nfpm() { unshare --uts --map-root-user sh -c 'hostname "$0" && exec nfpm "$@"' "${RPM_BUILDHOST:-build.example.internal}" "$@"; }
DEB="${ROOT}/deploy-artifacts/yoloman-agent_${VERSION}_amd64.deb"
RPM="${ROOT}/deploy-artifacts/yoloman-agent_${VERSION}_amd64.rpm"
( cd packaging && nfpm package -f nfpm.yaml -p deb -t "${DEB}" )
( cd packaging && rpm_nfpm package -f nfpm.yaml -p rpm -t "${RPM}" )
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
