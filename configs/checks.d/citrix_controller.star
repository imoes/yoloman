# Citrix Controller State - read-only Starlark check module
# Source: Checkmk checkmk.citrix_controller
#
# NOTE: This Checkmk plugin obtains its data from a special agent that queries
# the Citrix Delivery Controller REST API over the network. The Citrix controller
# is a separate host; there is NO on-host data source on the monitored machine
# that provides this data (no local binary, /proc, /sys entry, or config file
# that contains the controller state, licensing state, sessions, etc.).
# Per the translation rules, when a plugin's data comes from a special agent
# over the network with no local substitutable source, the honest translation
# reports absence: empty discovery and UNKNOWN in check mode.

SERVER_STATES = {
    "ServerNotSpecified": ("CRIT", "server not specified"),
    "NotConnected": ("WARN", "not connected"),
    "OK": ("OK", "OK"),
    "LicenseNotInstalled": ("CRIT", "license not installed"),
    "LicenseExpired": ("CRIT", "licenese expired"),
    "Incompatible": ("CRIT", "incompatible"),
    "Failed": ("CRIT", "failed"),
}

GRACE_STATES = {
    "NotActive": ("OK", "not active"),
    "Active": ("CRIT", "active"),
    "InOutOfBoxGracePeriod": ("WARN", "in-out-of-box grace period"),
    "InSupplementalGracePeriod": ("WARN", "in-supplemental grace period"),
    "InEmergencyGracePeriod": ("CRIT", "in-emergency grace period"),
    "GracePeriodExpired": ("CRIT", "grace period expired"),
    "Expired": ("CRIT", "expired"),
}

def _grade_level(value, warn, crit):
    # Upper-level grading: WARN if >= warn, CRIT if >= crit
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        # The data for this check comes from a Checkmk special agent querying
        # the Citrix Delivery Controller REST API over the network. There is no
        # on-host source on the monitored host. We must probe for the real thing.
        # Check if a Citrix controller is configured/reachable via the special
        # agent's data source — absent that, discovery yields nothing.
        return {
            "changed": False,
            "msg": "discovered 0 items: Citrix Delivery Controller data source not available on this host",
            "data": {"discovery": []},
        }

    # Check mode — the item from discovery
    item = params.get("item", "")
    # No on-host data source exists for this check. Report UNKNOWN.
    return {
        "changed": False,
        "msg": "Citrix Delivery Controller data not available on this host (data comes from a network special agent)",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }