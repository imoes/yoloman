# Starlark check module: bluecat_ha — HA State (Checkmk SNMP translation)
# Read-only monitor of a Bluecat HA device operational state via SNMP.
# Never mutates the system; always returns changed=False.

# OID base for the Bluecat HA operational-state scalar.
_HA_BASE = ".1.3.6.1.4.1.13315.3.1.5.2.1"
_HA_OPER_STATE_OID = _HA_BASE + ".1"

# SysObjectID that identifies a Bluecat device (used by DETECT_BLUECAT).
_BLUECAT_SYS_OBJECTID_OID = ".1.3.6.1.2.1.1.2.0"
_BLUECAT_SYS_OBJECTID_VALUE = ".1.3.6.1.4.1.13315.2.1"

# Operational-state code -> human-readable label.
_OPER_STATE_MAP = {
    "1": "standalone",
    "2": "active",
    "3": "passiv",
    "4": "stopped",
    "5": "stopping",
    "6": "becoming active",
    "7": "becomming passive",
    "8": "fault",
}

# Default threshold mapping (Checkmk check_default_parameters).
_DEFAULT_WARN = [5, 6, 7]
_DEFAULT_CRIT = [8, 4]


def _snmpget_scalar(ctx, host, community, version, oid):
    res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        fail("snmpget failed for " + oid + ": " + res.stderr)
    return res.stdout.strip()


def _probe_bluecat(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    val = _snmpget_scalar(ctx, host, community, version, _BLUECAT_SYS_OBJECTID_OID)
    return val == _BLUECAT_SYS_OBJECTID_VALUE


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    if params.get("_discover"):
        if not _probe_bluecat(ctx, params):
            return {
                "changed": False,
                "msg": "no Bluecat device detected",
                "data": {"discovery": []},
            }

        oper_state = _snmpget_scalar(ctx, host, community, version, _HA_OPER_STATE_OID)
        if oper_state == "1":
            return {
                "changed": False,
                "msg": "device is standalone, no HA service",
                "data": {"discovery": []},
            }

        return {
            "changed": False,
            "msg": "discovered HA State service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "warn": params.get("warn", _DEFAULT_WARN),
                            "crit": params.get("crit", _DEFAULT_CRIT),
                        },
                        "metrics": [],
                    }
                ]
            },
        }

    if not _probe_bluecat(ctx, params):
        return {
            "changed": False,
            "msg": "no Bluecat device detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    oper_state_raw = _snmpget_scalar(ctx, host, community, version, _HA_OPER_STATE_OID)
    if oper_state_raw not in _OPER_STATE_MAP:
        return {
            "changed": False,
            "msg": "unknown operational state code: " + str(oper_state_raw),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    oper_state = int(oper_state_raw)
    label = _OPER_STATE_MAP[oper_state_raw]

    if oper_state == 1:
        return {
            "changed": False,
            "msg": "State is " + label,
            "data": {"state": "OK", "metrics": {}, "details": "device is standalone"},
        }

    warn_states = params.get("warn", _DEFAULT_WARN)
    crit_states = params.get("crit", _DEFAULT_CRIT)

    if oper_state in crit_states:
        state = "CRIT"
    elif oper_state in warn_states:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "State is " + label,
        "data": {"state": state, "metrics": {}, "details": ""},
    }