# The Bossman-side poller agent (Block K6): a normal agentic-mcpd running
# alongside Bossman with SNMP/SSH CLI tools installed, so it can execute the
# SNMP/SSH checks against remote devices that have no agent of their own. It
# enrolls itself with Bossman on first boot and then looks like any other host.
#
# Build context is the repo root. The static binary is built on the host
# (scripts/build-agent-deb.sh style — `CGO_ENABLED=0 go build -o
# deploy-artifacts/agentic-mcpd ./cmd/agentic-mcpd`) and copied in, because
# this build environment can't reach proxy.golang.org to `go mod download`.

FROM debian:bookworm-slim
# snmp = snmpwalk/snmpget (SNMP checks); openssh-client = SSH checks;
# openssl = self-signed TLS cert at first boot; curl = health/debug.
RUN apt-get update && apt-get install -y --no-install-recommends \
        snmp openssh-client openssl ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY deploy-artifacts/agentic-mcpd /usr/bin/agentic-mcpd
COPY deploy/poller/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/bin/agentic-mcpd
EXPOSE 8010
ENTRYPOINT ["/entrypoint.sh"]
