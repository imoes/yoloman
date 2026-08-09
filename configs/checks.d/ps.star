# Checkmk check: ps (Process monitoring)
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# The Checkmk `ps` check is agent-supplied (it relies on a parsed section from
# `cmk.agent_based.v2`/`ps` library data — not something we can re-read locally
# as a single stable source). On our host-only agent without Checkmk we have no
# such section, so the honest translation reports absence: discovery yields an
# empty list and check mode returns UNKNOWN.

def main(ctx, params):
    # No Checkmk sections / libraries are available here. The `ps` check is
    # driven entirely by Checkmk's parsed agent section (process lines,
    # cpu/mem info). We have no equivalent on-host source, so the monitored
    # product is not present on this host.
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 0 processes (no Checkmk ps section available)",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    return {
        "changed": False,
        "msg": "no process data available for item " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "The Checkmk 'ps' check requires its parsed agent section, " +
                       "which is not provided by this host-only agent.",
        },
    }