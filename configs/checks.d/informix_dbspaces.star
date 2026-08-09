# ===== check plugin: cmk/plugins/ibm_informix/agent_based/informix_dbspaces.py =====
# Translated to read-only Starlark check module for the yolo-man agent.
#
# Data source note: This original Checkmk check consumes the "informix_dbspaces"
# agent section, which is produced by a Checkmk SPECIAL AGENT that connects to
# an IBM Informix database server over the network and runs Informix-specific
# SQL (syschunks, sysdbspaces, etc.). There is no equivalent on-host command,
# file, or socket on a generic Linux host that yields this data. Per the
# translation contract, absence of the monitored product/device is reported as
# no discovery items and UNKNOWN state, rather than substituting local sources.

FLAG_BLOBSPACE = 512


def main(ctx, params):
    if params.get("_discover"):
        # This check relies on data only available via the Checkmk special
        # agent connecting to an IBM Informix server over the network. There
        # is no local on-host source that produces this section, so this
        # check does not apply to this host.
        return {
            "changed": False,
            "msg": "discovered 0 items (no local IBM Informix dbspace source)",
            "data": {"discovery": []},
        }

    # Check mode for a specific item.
    # The required data (IBM Informix dbspace sizes/flags/chunks) is not
    # available locally; we cannot fabricate it.
    return {
        "changed": False,
        "msg": "UNKNOWN - IBM Informix dbspace data not available locally; requires the Checkmk special agent for Informix",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "No local source for IBM Informix dbspace information exists on this host. The original Checkmk check consumes the 'informix_dbspaces' agent section, fetched by a Checkmk special agent over the network from an Informix server.",
        },
    }