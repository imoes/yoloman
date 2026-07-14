#!/usr/bin/env bash
# Build the standalone-agent frontend (the Angular `agent-ui` app in the
# bossman-ui workspace) and embed it into the agent binary's webui assets.
# The agent serves it at /ui via internal/webui (go:embed), so it ships inside
# the normal agent .deb — no separate frontend package. Run before building the
# agent whenever the agent-ui source changes.
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">> building agent-ui (Angular, baseHref /ui/)"
( cd bossman-ui && npx ng build agent-ui )

echo ">> embedding into internal/webui/assets"
rm -f internal/webui/assets/*
cp -r bossman-ui/dist/agent-ui/browser/* internal/webui/assets/

echo ">> embedded assets:"
ls -1 internal/webui/assets/
echo ">> done — now build the agent (scripts/build-agent-deb.sh) to bake it in."
