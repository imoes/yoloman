def main(ctx, params):
    # Discovery mode: yield one service with empty item
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": []}
            ]},
        }

    # Check mode: look for agent data
    # Try JSON file first
    path = "/var/lib/check-mk-agent/audit/audiocodes_overall_operational_state.json"
    content = ""
    if ctx.file_exists(path):
        content = ctx.file_read(path)
        # Try to decode JSON
        data = json.decode(content)
        if type(data) == "list" and len(data) >= 4:
            op_state_str = str(data[0])
            gw_severity_str = str(data[1])
            error_message = str(data[2]) if data[2] != None else ""
            error_id = str(data[3]) if data[3] != None else ""
        else:
            fail("invalid agent data format: not a list with 4 elements")
    else:
        # Try alternative text-based file
        path = "/var/lib/check-mk-agent/spool/audiocodes_overall_operational_state"
        if ctx.file_exists(path):
            content = ctx.file_read(path)
            parts = content.strip().split()
            if len(parts) >= 4:
                op_state_str = parts[0]
                gw_severity_str = parts[1]
                error_message = parts[2]
                error_id = parts[3]
            elif len(parts) == 2:
                op_state_str = parts[0]
                gw_severity_str = parts[1]
                error_message = ""
                error_id = ""
            else:
                fail("invalid agent data format: expected at least 2 fields")
        else:
            return {
                "changed": False,
                "msg": "no agent data available for audiocodes_overall_operational_state",
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": ""
                },
            }

    # Map states as in the Python source
    op_state_map = {
        "0": "OK",
        "1": "UNKNOWN",
        "2": "WARN",
        "3": "CRIT",
    }
    op_state_name = op_state_map.get(op_state_str, "UNKNOWN")
    op_state_state = op_state_map.get(op_state_str, "UNKNOWN")

    # GW_SEVERITY_MAPPING
    gw_severity_map = {
        "0": ("No alarm", "OK"),
        "1": ("Indeterminate", "UNKNOWN"),
        "2": ("Warning", "WARN"),
        "3": ("Minor", "WARN"),
        "4": ("Major", "CRIT"),
        "5": ("Critical", "CRIT"),
    }
    gw_severity_tuple = gw_severity_map.get(gw_severity_str, ("Indeterminate", "UNKNOWN"))
    gw_severity_name = gw_severity_tuple[0]
    gw_severity_state = gw_severity_tuple[1]

    # Determine overall state: CRIT > WARN > UNKNOWN > OK
    def state_worse(s1, s2):
        order = {"CRIT": 3, "WARN": 2, "UNKNOWN": 1, "OK": 0}
        return s1 if order.get(s1, 0) >= order.get(s2, 0) else s2

    final_state = state_worse(gw_severity_state, op_state_state)

    # Build message
    msg = "Gateway: " + gw_severity_name + ", Highest alarm severity: " + op_state_name

    details = ""
    if error_message != "" or error_id != "":
        details = "Error message: " + (error_message if error_message != "" else "(empty)") + "\nError ID: " + (error_id if error_id != "" else "(empty)")

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": final_state,
            "metrics": {},
            "details": details
        },
    }
