#!/usr/bin/env bash
# Long-lived test HOSTS in minikube: agent pods that enroll with the local Bossman, so the Bossman path (wizard,
# role deployments, policies) and the Playwright scenarios run against real managed hosts.
#
#   deploy/test-images/agent-hosts.sh up|down|status
#
# Hosts (name  family  write-gate):
#   e2e-deb-1, e2e-deb-2   debian   on       — two of a family: pilot + main phase, host groups
#   e2e-rh-1,  e2e-rh-2    redhat   on
#   e2e-deb-ro             debian   off      — enrolled read-only: a deployment must end `blocked` with its reason
#
# REACHABILITY, both ways, measured before relying on it:
#   pod -> Bossman   the docker-network gateway 192.168.49.1, where compose publishes Bossman on :8123
#   Bossman -> pod   a NodePort per host on the minikube node 192.168.49.2; the Bossman container is attached to
#                    the minikube network here (`docker network connect` — not persistent across a compose recreate,
#                    which is why `up` re-does it every time instead of a compose override that would break
#                    `docker compose up` whenever minikube is down).
# The agent listens on the SAME port it advertises (register binds the listen from --address), so the NodePort,
# the targetPort and the advertised port are one number.
set -euo pipefail
CTX=${MINIKUBE_PROFILE:-bossman-dev}
NS=pkg-e2e-hosts
NODE_IP=$(minikube -p "$CTX" ip)
GATEWAY=${BOSSMAN_ENROLL_URL:-http://192.168.49.1:8123}
BOSSMAN_CONTAINER=${BOSSMAN_CONTAINER:-agentic-mcp-bossman-1}
IMAGES=${AGENTIC_BATCH_LOG_DIR:-$HOME/.local/state/agentic-batches}/pkg-e2e-images.json
PROXY=${YOLOMAN_HTTP_PROXY:-http://proxy.example.internal:80}
export NO_PROXY=192.168.49.0/24,localhost,127.0.0.1 no_proxy=192.168.49.0/24,localhost,127.0.0.1
K="kubectl --context $CTX -n $NS"

HOSTS=(
  "e2e-deb-1 debian 30811 true"
  "e2e-deb-2 debian 30812 true"
  "e2e-rh-1 redhat 30821 true"
  "e2e-rh-2 redhat 30822 true"
  "e2e-deb-ro debian 30813 false"
)

# The systemd HOST image: the agent runs as the packaged service and roles can restart daemons, as on a real host.
image() { python3 -c "import json,sys;print(json.load(open('$IMAGES'))['$1_host'])"; }

up() {
  kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
  docker network connect "$CTX" "$BOSSMAN_CONTAINER" 2>/dev/null || true
  for h in "${HOSTS[@]}"; do
    read -r name fam port write <<<"$h"
    img=$(image "$fam")
    cat <<EOF | $K apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata: {name: $name, labels: {app: e2e-host}}
spec:
  type: NodePort
  selector: {host: $name}
  ports: [{name: agent, port: $port, targetPort: $port, nodePort: $port}]
---
apiVersion: v1
kind: Pod
metadata: {name: $name, labels: {app: e2e-host, host: $name, family: $fam}}
spec:
  hostname: $name
  containers:
  - name: host
    image: $img
    imagePullPolicy: Never
    securityContext: {privileged: true}
    env:
    - {name: E2E_ENROLL_URL, value: "$GATEWAY"}
    - {name: E2E_NAME, value: "$name"}
    - {name: E2E_ADDRESS, value: "$NODE_IP:$port"}
    - {name: E2E_WRITE, value: "$write"}
    - {name: http_proxy, value: "$PROXY"}
    - {name: https_proxy, value: "$PROXY"}
    - {name: no_proxy, value: "192.168.49.0/24,.example.internal,localhost"}
    ports: [{containerPort: $port}]
    volumeMounts: [{name: run, mountPath: /run}, {name: runlock, mountPath: /run/lock}, {name: tmp, mountPath: /tmp}]
    resources: {requests: {cpu: 100m, memory: 192Mi}, limits: {memory: 2Gi}}
  volumes:
  - {name: run, emptyDir: {medium: Memory}}
  - {name: runlock, emptyDir: {medium: Memory}}
  - {name: tmp, emptyDir: {}}
EOF
    echo "applied $name ($fam, write=$write) → $NODE_IP:$port"
  done
  $K wait --for=condition=Ready pod -l app=e2e-host --timeout=180s >/dev/null && echo "all host pods ready"
}

down() { $K delete pod,svc -l app=e2e-host --ignore-not-found; }
status() { $K get pod,svc -l app=e2e-host -o wide; }

"${1:-status}"
