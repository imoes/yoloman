
# Operational state mapping from the Bluecat command server MIB
_OPER_STATE_MAP = {
    1: "running normally",
    2: "not running",
    3: "currently starting",
    4: "currently stopping",
    5: "fault",
}

# OID base for the BlueCat command server operational state
_BLUECAT_CMD_SERVER_OID = ".1.3.6.1.2.1.1.2.0"

# OID for the BlueCat vendor identity (sysObjectID) used for detection
_BLUECAT_DETECT_OID = ".1.3.6.1.2.1.1.2.0"
_BLUECAT_DETECT_VALUE = ".1.3.6.1.4.1.13315.2.1"

# The actual data OID: base .1.3.6.1.4.1.13315.3.1.7.2.1, column 1
_CMD_SERVER_BASE_OID = ".1.3.6.1.4.1.13315.3.1.7.2.1"
_CMD_SERVER_COLUMN_OID = ".1.3.6.1.4.1.13315.3.1.7.2.1.1"


def _probe_bluecat_presence(ctx, host, community):
    # Detect BlueCat by checking sysObjectID
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, _BLUECAT_DETECT_OID
    ], mutates=False)
    if res.rc == 127:
        return False
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    # Compare the OID value; BlueCat sysObjectID is .1.3.6.1.4.1.13315.2.1
    return val.endswith("13315.2.1")


def _fetch_oper_state(ctx, host, community):
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, _CMD_SERVER_COLUMN_OID
    ], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe for BlueCat presence first
        if not _probe_bluecat_presence(ctx, host, community):
            return {
                "changed": False,
                "msg": "no BlueCat device found",
                "data": {"discovery": []},
            }
        # This is a single-service check (one Command Server per device)
        warn_default = [2, 3, 4]
        crit_default = [5]
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "oper_states": {
                                "warning": warn_default,
                                "critical": crit_default,
                            },
                        },
                        "metrics": [],
                    }
                ]
            },
        }

    # Check mode: read the operational state
    oper_state_str = _fetch_oper_state(ctx, host, community)
    if oper_state_str == None:
        return {
            "changed": False,
            "msg": "Command Server operational state not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse the SNMP value - it may be a bare integer or have a trailing index
    parts = oper_state_str.split()
    if len(parts) == 0:
        return {
            "changed": False,
            "msg": "Command Server operational state not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    raw_val = parts[-1]
    if not raw_val.isdigit():
        return {
            "changed": False,
            "msg": "Command Server operational state not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    oper_state = int(raw_val)

    # Apply threshold logic from params (Checkmk defaults)
    oper_states = params.get("oper_states", {})
    warn_states = oper_states.get("warning", [2, 3, 4])
    crit_states = oper_states.get("critical", [5])

    state = "OK"
    if oper_state in crit_states:
        state = "CRIT"
    elif oper_state in warn_states:
        state = "WARN"

    desc = _OPER_STATE_MAP.get(oper_state, "unknown")
    msg = "Command Server is " + desc

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }