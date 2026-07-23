def main(ctx, params):
    # Discovery mode: synology_status yields one service per host
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ]
            },
        }

    # Check mode: fetch status via agent (assume synology agent plugin is installed)
    # We expect a simple command that outputs: "<system_status> <power_status>"
    # Common approaches: syno_info --status, synology_status, or parsing from agent section
    # Since the check is SNMP-based but we cannot run SNMP directly, we rely on
    # agent plugins that provide this data. We'll try a standard command.
    res = ctx.run(["synology_status_get"], mutates=False)
    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return {
            "changed": False,
            "msg": "No data from agent (synology_status_get failed)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse the first line: two integers
    parts = lines[0].split()
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "Invalid data format (expected two integers)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Guard: check if parts can be converted to int
    sys_str = parts[0]
    pow_str = parts[1]
    if not sys_str.isdigit() or not pow_str.isdigit():
        return {
            "changed": False,
            "msg": "Invalid data format (non-integer values)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    system_status = int(sys_str)
    power_status = int(pow_str)

    # Build summary and state
    msg_parts = []
    state = "OK"

    if system_status != 1:
        msg_parts.append("System Failure")
        state = "CRIT"
    else:
        msg_parts.append("System state OK")

    if power_status != 1:
        msg_parts.append("Power Failure")
        state = "CRIT"
    else:
        msg_parts.append("Power state OK")

    msg = ", ".join(msg_parts)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
