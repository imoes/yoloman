# Checkmk check: hepta_syncmoduletimelocal
# Translated to read-only Starlark for the yolo-man agent.
#
# Source Checkmk plugin (cmk/plugins/hepta/agent_based/hepta.py) reads an HPF
# (Hopf) GPS clock via SNMP trees under .1.3.6.1.4.1.12527 (.29 and .40).
# The sync-module-time-local check reports the decoded local module time held
# by a section named "hepta" (the 7th OID of whichever tree is present).

# --- Constants mirroring the Checkmk SNMPSection / SNMPTree in the source ---

HPF_ENTERPRISE_PREFIX = ".1.3.6.1.4.1.12527"

# Two SNMP trees carry the "hepta" section; either may be present.
SNMPSectionTrees = [
    ".1.3.6.1.4.1.12527.29",
    ".1.3.6.1.4.1.12527.40",
]

# OIDs fetched in order within each tree (relative to the tree base).
SNMPSectionOIDs = [
    "1.1.0", "1.3.0", "1.4.0", "1.5.0", "1.6.0", "2.1.2.0", "3.1.0", "3.5.0",
]

# The "local sync module time" is the 7th OID (index 6), OID suffix 3.1.0
# relative to each tree base. This is what the check reports.
LOCAL_TIME_REL_OID = "3.1.0"

# Default SNMP connection parameters (operator-configurable).
DEFAULT_HOST = "localhost"
DEFAULT_COMMUNITY = "public"
DEFAULT_VERSION = "2c"


def _snmp_get(ctx, host, community, version, oid):
    """Read a single scalar SNMP value via net-snmp -Oqv (bare value)."""
    return ctx.run(
        ["snmpget", "-Oqv", "-v" + version, "-c", community, host, oid],
        mutates=False,
    )


def _section_present(ctx, params):
    """Detect whether this host is an HPF clock AND has a usable hepta section.

    Mirrors the Checkmk detect/startswith(".1.3.6.1.2.1.1.2.0", enterprise prefix)
    plus the two SNMPTree fetches. Returns the decoded local time string, or
    None when the device / data is absent.
    """
    host = params.get("host", DEFAULT_HOST)
    community = params.get("community", DEFAULT_COMMUNITY)
    version = params.get("version", DEFAULT_VERSION)

    # Detection: the device's sysObjectID must be an HPF enterprise device.
    sysid = _snmp_get(ctx, host, community, version, ".1.3.6.1.2.1.1.2.0")
    if sysid.rc != 0:
        # rc 127 => snmpget not installed; rc 2/timeout => no such device.
        # Either way: not present here.
        return None
    sysid_val = sysid.stdout.strip()
    if not sysid_val.startswith(HPF_ENTERPRISE_PREFIX):
        return None

    # Fetch the local sync-module time from whichever tree is populated.
    for base in SNMPSectionTrees:
        oid = base + "." + LOCAL_TIME_REL_OID
        res = _snmp_get(ctx, host, community, version, oid)
        if res.rc == 0 and res.stdout.strip() != "":
            return res.stdout.strip()
    return None


def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        local = _section_present(ctx, params)
        if local == None:
            # Not an HPF clock / no data -> this check does not apply here.
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        # Single-service check: one item, "" (no per-item breakdown).
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []},
                ],
            },
        }

    # --- CHECK MODE ---
    # (params.get("item", "") == "" for a single-service check.)
    local = _section_present(ctx, params)
    if local == None:
        return {
            "changed": False,
            "msg": "not present: no HPF sync module time found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    return {
        "changed": False,
        "msg": "Module Time: " + local,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }