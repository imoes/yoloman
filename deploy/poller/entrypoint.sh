#!/bin/sh
# First-boot bootstrap for the Bossman-side poller agent (Block K6):
#  1. write a config.yaml with a fresh token + a self-signed TLS server cert
#     (Bossman pulls with verify=False, so any cert works; trusted_client_keys
#     is left empty so read pulls aren't gated on a client cert — mirrors the
#     working docker-test setup);
#  2. enroll with Bossman so it appears as a host and gets polled;
#  3. run the daemon.
# Idempotent: an existing config.yaml is kept, so a restart resumes.
set -e

CONF=/etc/agentic-mcp/config.yaml
ENROLL_URL="${ENROLL_URL:-http://bossman:8000}"
POLLER_NAME="${POLLER_NAME:-bossman-poller}"
POLLER_ADDRESS="${POLLER_ADDRESS:-bossman-poller:8010}"

mkdir -p /etc/agentic-mcp/trusted /var/lib/agentic-mcp

if [ ! -f "$CONF" ]; then
    echo "poller: first boot — generating config, token, self-signed cert"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout /etc/agentic-mcp/tls.key -out /etc/agentic-mcp/tls.crt \
        -days 3650 -subj "/CN=${POLLER_NAME}" >/dev/null 2>&1
    TOKEN="$(agentic-mcpd --generate-token)"
    cat > "$CONF" <<EOF
listen: "0.0.0.0:8010"
token: "${TOKEN}"
write: false
tls:
  enabled: true
  cert_file: /etc/agentic-mcp/tls.crt
  key_file: /etc/agentic-mcp/tls.key
  # Bossman presents a client cert when it pulls; the enrollment handshake
  # below writes Bossman's public key here, so trusting it lets Bossman's
  # reads through (otherwise every poll is 403). The daemon starts only after
  # enrollment, so the file exists by serve time.
  trusted_client_keys:
    - name: enroller
      public_key_path: /etc/agentic-mcp/trusted/enroller.pub.pem
ebpf:
  enabled: false
db:
  driver: sqlite
  path: /var/lib/agentic-mcp/agentic-mcp.db
pam:
  enabled: false
ui:
  enabled: false
EOF
    chmod 0600 "$CONF"
fi

# Enroll with Bossman (open enrollment). Retry until Bossman is reachable; a
# repeat enrollment of an already-known name is a harmless no-op update.
i=0
while [ "$i" -lt 40 ]; do
    if agentic-mcpd register --enroll-url "$ENROLL_URL" \
            --name "$POLLER_NAME" --address "$POLLER_ADDRESS" --config "$CONF"; then
        echo "poller: enrolled with $ENROLL_URL"
        break
    fi
    i=$((i + 1))
    echo "poller: enroll attempt $i failed, retrying in 3s…"
    sleep 3
done

exec agentic-mcpd --config "$CONF"
