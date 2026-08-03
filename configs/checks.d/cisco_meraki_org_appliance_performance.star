# Cisco Meraki Organization Appliance Performance — read-only Checkmk check as Starlark
#
# This check needs data that originates from the Meraki Dashboard API
# (a cloud service). It is NOT available from the local host's /proc or /sys,
# and no Meraki agent runs on-host. A faithful read-only translation therefore
# reports absence on every host: empty discovery and UNKNOWN verdict.

def main(ctx, params):
    # Single-service check (Discovery yields exactly one Service()).
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    # Check mode — data source unavailable on this host.
    return {
        "changed": False,
        "msg": "no Meraki Dashboard data source available on this host",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }