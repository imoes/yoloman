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
#   ./deploy-artifacts/agentic-mcp_<ver>_amd64.deb   a versioned copy
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
export VERSION
echo ">> building agent version ${VERSION}"

ROOT="$(pwd)"
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o agentic-mcpd ./cmd/agentic-mcpd

mkdir -p deploy-artifacts
# nfpm resolves the config's relative src paths (../agentic-mcpd, ../configs/…)
# against the CWD, so run it from packaging/. Output to absolute paths.
( cd packaging && nfpm package -f nfpm.yaml -p deb -t "${ROOT}/deploy-artifacts/agentic-mcp_${VERSION}_amd64.deb" )
cp -f "${ROOT}/deploy-artifacts/agentic-mcp_${VERSION}_amd64.deb" "${ROOT}/deploy-artifacts/agent.deb"

echo ">> built:"
ls -la deploy-artifacts/*.deb
echo ">> deploy-artifacts/agent.deb is what the UI Update button (BOSSMAN_AGENT_DEB_PATH) serves."
