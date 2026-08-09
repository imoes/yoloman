# synology_update — Checkmk check translated to read-only Starlark
# Monitors Synology DSM update availability/status via SNMP

# OID base and columns for the synology_update SNMP section
# Fetch: .1.3.6.1.4.1.6574.1.5.3 (Version), .1.3.6.1.4.1.6574.1.5.4 (Status)
_OID_BASE = ".1.3.6.1.4.1.6574.1.5"
_OID_VERSION = _OID_BASE + ".3"
_OID_STATUS = _OID_BASE + ".4"

# synology.DETECT: system family is "synology" based on
# .1.3.6.1.4.1.6574.1.1 and .1.3.6.1.4.1.6574.1.2
_OID_FAMILY = ".1.3.6.1.4.1.6574.1.1"
_OID_MODEL = ".1.3.6.1.4.1.6574.1.2"

_STATES = {
    1: "Available",
    2: "Unavailable",
    3: "Connecting",
    4: "Disconnected",
    5: "Others",
}

def _is_synology(ctx, host, community):
    """Probe that this is a Synology device via syserobotics MIB."""
    fam = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_FAMILY],
        mutates=False,
    )
    if fam.rc != 0:
        return False
    model = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_MODEL],
        mutates=False,
    )
    return model.rc == 0

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Probe for the real thing first
        if not _is_synology(ctx, host, community):
            return {
                "changed": False,
                "msg": "device is not a Synology system",
                "data": {"discovery": []},
            }
        version_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_VERSION],
            mutates=False,
        )
        status_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_STATUS],
            mutates=False,
        )
        if version_res.rc != 0 and status_res.rc != 0:
            return {
                "changed": False,
                "msg": "synology_update section unavailable",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {
                        "ok_states": [2],
                        "warn_states": [5],
                        "crit_states": [1, 4],
                    },
                    "metrics": [],
                }
            ]},
        }

    # Check mode
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if not _is_synology(ctx, host, community):
        return {
            "changed": False,
            "msg": "not a Synology device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    version_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_VERSION],
        mutates=False,
    )
    status_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_STATUS],
        mutates=False,
    )

    if version_res.rc != 0 and status_res.rc != 0:
        return {
            "changed": False,
            "msg": "no update data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    version = version_res.stdout.strip()
    status_str = status_res.stdout.strip()

    status = int(status_str) if status_str.isdigit() else 0

    ok_states = params.get("ok_states", [2])
    warn_states = params.get("warn_states", [5])
    crit_states = params.get("crit_states", [1, 4])

    if status == 3:
        # Devices try to connect to the update server — prevent flapping
        return {
            "changed": False,
            "msg": "Update Status: Connecting, Current Version: " + version,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Devices try to connect to the update server"},
        }

    if status in ok_states:
        state = "OK"
    elif status in warn_states:
        state = "WARN"
    elif status in crit_states:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    label = _STATES.get(status, "Unknown")
    return {
        "changed": False,
        "msg": "Update Status: " + label + ", Current Version: " + version,
        "data": {"state": state, "metrics": {}, "details": ""},
    }