# Juniper chassis alarm check (read-only Starlark module)
# Translated from cmk.plugins.juniper.alarm

_STATE_MAP = {
    "state_1": "unknown or unavailable",
    "state_2": "OK, good, normally working",
    "state_3": "alarm, warning, marginally working (minor)",
    "state_4": "alert, failed, not working (major)",
    "state_5": "OK, online as an active primary",
    "state_6": "alarm, offline, not running (minor)",
    "state_7": "off-line, not running",
    "state_8": "entering state of ok, good, normally working",
    "state_9": "entering state of alarm, warning, marginally working",
    "state_10": "entering state of alert, failed, not working",
    "state_11": "entering state of ok, on-line as an active primary",
    "state_12": "entering state of off-line, not running",
}

# Default parameter mapping: state_N -> State value (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN)
_CHECK_DEFAULT_PARAMS = {
    "state_1": 3,
    "state_2": 0,
    "state_3": 1,
    "state_4": 2,
    "state_5": 0,
    "state_6": 1,
    "state_7": 2,
    "state_8": 0,
    "state_9": 1,
    "state_10": 2,
    "state_11": 0,
    "state_12": 1,
}


def main(ctx, params):
    # Discovery mode: always yield one Service for "Chassis"
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": _CHECK_DEFAULT_PARAMS, "metrics": []}
                ]
            },
        }

    # Check mode: single-service (item is always "")
    # Get alarm state via SNMP probe (OID .1.3.6.1.4.1.2636.3.1.10.1.8)
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.2636.3.1.10.1.8"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Failed to retrieve Juniper alarm state"
            }
        }

    # Parse SNMP output: expected format "SNMPv2-SMI::mib-2636.3.1.10.1.8 = STRING: \"<state>\""
    out = res.stdout.strip()
    lines = out.splitlines()
    if len(lines) < 1:
        return {
            "changed": False,
            "msg": "No data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Empty SNMP response"}
        }

    # Extract state value: look for "STRING: \"<value>\"" or similar pattern
    line = lines[0]
    # Split on '=' and get the right-hand part
    if "=" not in line:
        return {
            "changed": False,
            "msg": "Parse error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Cannot parse SNMP response"}
        }

    rhs = line.split("=", 1)[1].strip()
    # Remove quotes and whitespace
    state_raw = rhs.strip('"\'').strip()
    
    # Only process if state_raw is a digit
    if not state_raw.isdigit():
        return {
            "changed": False,
            "msg": "Invalid alarm state",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Non-numeric alarm state: " + state_raw}
        }

    state_value = int(state_raw)
    state_formatted = "state_" + str(state_value)

    # Determine state priority: warn if value >= warn, crit if value >= crit
    # Checkmk state constants: OK=0, WARN=1, CRIT=2, UNKNOWN=3
    priority = params.get(state_formatted, 3)
    state_str = "UNKNOWN"
    if priority == 0:
        state_str = "OK"
    elif priority == 1:
        state_str = "WARN"
    elif priority == 2:
        state_str = "CRIT"

    summary = _STATE_MAP.get(state_formatted, "unhandled alarm type '%s'" % state_raw)
    return {
        "changed": False,
        "msg": "Status: " + summary,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }
