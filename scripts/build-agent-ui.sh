#!/usr/bin/env bash
# Build the standalone-agent frontend (the Angular `agent-ui` app in the
# bossman-ui workspace) and embed it into the agent binary's webui assets.
# The agent serves it at /ui via internal/webui (go:embed), so it ships inside
# the normal agent .deb — no separate frontend package. Run before building the
# agent whenever the agent-ui source changes.
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">> building agent-ui (Angular standalone console, baseHref /ui/)"
# Second entry point of the bossman-ui project (src/agent-main.ts) — reuses the
# fleet host components against the agent's own API. See angular.json
# bossman-ui:build configuration "agent".
( cd bossman-ui && npx ng build bossman-ui --configuration agent )

echo ">> embedding into internal/webui/assets"
rm -rf internal/webui/assets/*   # -rf: also clears prior build's assets/ + media/ subdirs
cp -r bossman-ui/dist/agent-ui/browser/. internal/webui/assets/   # /. copies top-level files + subdirs

echo ">> embedded assets:"
ls -1 internal/webui/assets/
echo ">> done — now build the agent (scripts/build-agent-deb.sh) to bake it in."
