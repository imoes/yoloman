#!/usr/bin/env bash
# Build both package-e2e images and load them into the minikube profile.
#   deploy/test-images/build.sh [AGENT_VERSION]
#
# EVERY BUILD GETS ITS OWN TAG (agent version + content hash of the build context) and the tags are written to
# ~/.local/state/agentic-batches/pkg-e2e-images.json, which the runner reads. A fixed `:latest` looked fine and
# was not: `minikube image load` does not replace a tag that a pod still uses, says nothing, and the next pod
# ran the OLD script.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
VER=${1:-$(ls "$REPO"/deploy-artifacts/yoloman-agent_*_amd64.deb | sed 's/.*agent_\(.*\)_amd64.deb/\1/' | sort -V | tail -1)}
PROFILE=${MINIKUBE_PROFILE:-bossman-dev}
PROXY=${YOLOMAN_HTTP_PROXY:?set YOLOMAN_HTTP_PROXY}
STATE=${AGENTIC_BATCH_LOG_DIR:-$HOME/.local/state/agentic-batches}/pkg-e2e-images.json
mkdir -p "$(dirname "$STATE")"
# The repo index baked into the images is refreshed once a day (see REPO_SNAPSHOT in the Dockerfiles).
SNAP=${REPO_SNAPSHOT:-$(date +%F)}
declare -A TAGS
for img in debian-trixie almalinux9; do
  ctx=$(mktemp -d)
  cp "$img/Dockerfile" e2e-one.py "$ctx/"
  cp "$REPO/deploy-artifacts/yoloman-agent_${VER}_amd64.deb" "$ctx/agent.deb"
  cp "$REPO/deploy-artifacts/yoloman-agent_${VER}_amd64.rpm" "$ctx/agent.rpm"
  hash=$( (cat "$ctx/Dockerfile" "$ctx/e2e-one.py" "$ctx/agent.deb" "$ctx/agent.rpm"; echo "$SNAP") | sha256sum | cut -c1-10)
  tag="pkg-e2e/$img:${VER}-${hash}"
  docker build -q --build-arg REPO_SNAPSHOT="$SNAP" --build-arg http_proxy="$PROXY" --build-arg https_proxy="$PROXY" \
    -t "$tag" "$ctx" >/dev/null
  rm -rf "$ctx"
  minikube -p "$PROFILE" image load "$tag"
  minikube -p "$PROFILE" image ls | grep -q "${tag}$" || { echo "FAIL: $tag not in minikube after load"; exit 1; }
  TAGS[$img]=$tag
  echo "built + loaded $tag"
done
# The systemd HOST variants (agent as a service, wizard can restart daemons) — built FROM the images above.
declare -A HOSTTAGS
for pair in "debian-trixie debian" "almalinux9 redhat"; do
  read -r img fam <<<"$pair"
  hash=$(cat systemd/* | sha256sum | cut -c1-10)
  tag="pkg-e2e/${img}-systemd:${TAGS[$img]##*:}-${hash}"
  docker build -q --build-arg BASE="${TAGS[$img]}" --build-arg FAMILY="$fam" \
    --build-arg http_proxy="$PROXY" --build-arg https_proxy="$PROXY" -t "$tag" systemd >/dev/null
  minikube -p "$PROFILE" image load "$tag"
  minikube -p "$PROFILE" image ls | grep -q "${tag}$" || { echo "FAIL: $tag not in minikube after load"; exit 1; }
  HOSTTAGS[$fam]=$tag
  echo "built + loaded $tag"
done
printf '{"debian": "%s", "redhat": "%s", "debian_host": "%s", "redhat_host": "%s"}\n' \
  "${TAGS[debian-trixie]}" "${TAGS[almalinux9]}" "${HOSTTAGS[debian]}" "${HOSTTAGS[redhat]}" > "$STATE"
echo "tags -> $STATE"
