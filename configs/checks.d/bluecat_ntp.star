_OPER_STATE_MAP = {
    1: "running normally",
    2: "not running",
    3: "currently starting",
    4: "currently stopping",
    5: "fault",
}

_SYS_LEAP_STATE_MAP = {
    0: "no Warning",
    1: "add second",
    10: "subtract second",
    11: "Alarm",
}

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered NTP service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Default parameters (same as Checkmk defaults)
    default_oper_states = {"warning": [2, 3, 4], "critical": [5]}
    default_stratum = (8, 10)

    oper_states = params.get("oper_states", default_oper_states)
    stratum_levels = params.get("stratum", default_stratum)
    warn_stratum, crit_stratum = stratum_levels

    # Fetch SNMP data
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.13315.3.1.4.2"
    ], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse SNMP output: expected format ".1.3.6.1.4.1.13315.3.1.4.2.1.1 = INTEGER: 1"
    lines = res.stdout.splitlines()
    values = []
    for line in lines:
        if " = " not in line:
            continue
        oid_part, value_part = line.rsplit(" = ", 1)
        if ":" not in value_part:
            continue
        _, val_str = value_part.split(":", 1)
        val_str = val_str.strip()
        if val_str.isdigit():
            values.append(int(val_str))

    # We expect 3 values: oper_state, sys_leap, stratum
    if len(values) != 3:
        return {
            "changed": False,
            "msg": "incomplete SNMP data (expected 3 values, got %d)" % len(values),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    oper_state, sys_leap, stratum = values

    # Determine overall state
    state = "OK"
    summary_parts = []

    # Oper state check
    oper_state_summary = _OPER_STATE_MAP.get(oper_state, "unknown state")
    if oper_state in oper_states.get("critical", []):
        state = "CRIT"
    elif oper_state in oper_states.get("warning", []):
        if state == "OK":
            state = "WARN"
    summary_parts.append("Process is " + oper_state_summary)

    # Sys leap state check
    sys_leap_summary = _SYS_LEAP_STATE_MAP.get(sys_leap, "unknown leap state")
    if sys_leap == 11:
        state = "CRIT"
    elif sys_leap in [1, 10]:
        if state == "OK":
            state = "WARN"
    summary_parts.append("Sys Leap: " + sys_leap_summary)

    # Stratum check
    if stratum >= crit_stratum:
        state = "CRIT"
    elif stratum >= warn_stratum:
        if state == "OK":
            state = "WARN"
    summary_parts.append("Stratum: %d" % stratum)

    metrics = {
        "oper_state": oper_state,
        "sys_leap": sys_leap,
        "stratum": stratum,
    }

    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
