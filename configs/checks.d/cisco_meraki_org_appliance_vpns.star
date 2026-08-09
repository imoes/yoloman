# ===== translated from Checkmk check: cisco_meraki_org_appliance_vpns =====
# This is a CHECKMK SPECIAL-AGENT check: the VPN peer data is NOT available on
# the host's local filesystem or via SNMP. It is gathered by the Checkmk
# special agent that talks to the Cisco Meraki Dashboard REST API.
#
# The on-host Starlark runtime has NO access to the Meraki special-agent socket
# or to the Meraki API response, so this translation faithfully reports
# ABSENCE rather than inventing local data: discovery yields an empty list and
# the check returns UNKNOWN on every host.

STATUS_OK = "OK"
STATUS_WARN = "WARN"
STATE_OK = 0
STATE_WARN = 1
STATE_UNKNOWN = 3

# Default parameter mirroring Checkparams(status_not_reachable=State.WARN.value)
DEFAULT_STATUS_NOT_REACHABLE = STATE_WARN


def main(ctx, params):
    if params.get("_discover"):
        # The Meraki special-agent section is not present in this runtime.
        # Absence is the honest answer: do NOT synthesize placeholder peers.
        return {
            "changed": False,
            "msg": "Meraki appliance VPN special-agent data not available here",
            "data": {"discovery": []},
        }

    # CHECK MODE (single item)
    item = params.get("item", "")
    # No on-host source exists for Meraki VPN peers; report UNKNOWN, never OK.
    return {
        "changed": False,
        "msg": "Cisco Meraki appliance VPN data unavailable (special-agent API not reachable)",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }