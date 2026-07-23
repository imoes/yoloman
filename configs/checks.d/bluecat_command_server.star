_OPER_STATE_MAP = {
    1: "running normally",
    2: "not running",
    3: "currently starting",
    4: "currently stopping",
    5: "fault",
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }
    
    # Check mode: fetch SNMP data
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.13315.3.1.7.2.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse SNMP output: ".1.3.6.1.4.1.13315.3.1.7.2.1.1 = INTEGER: <value>"
    oper_state = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if ".1.3.6.1.4.1.13315.3.1.7.2.1.1" in stripped and "=" in stripped:
            idx = stripped.find("INTEGER:")
            if idx >= 0:
                value_part = stripped[idx + len("INTEGER:"):].strip()
                if value_part.isdigit():
                    oper_state = int(value_part)
                    break
    
    if oper_state == None or (oper_state < 1 or oper_state > 5):
        return {
            "changed": False,
            "msg": "Command Server state unknown",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Apply threshold logic
    defaults = {"oper_states": {"warning": [2, 3, 4], "critical": [5]}}
    params_oper_states = params.get("oper_states", defaults["oper_states"])
    warning_list = params_oper_states.get("warning", defaults["oper_states"]["warning"])
    critical_list = params_oper_states.get("critical", defaults["oper_states"]["critical"])
    
    state = "OK"
    if oper_state in critical_list:
        state = "CRIT"
    elif oper_state in warning_list:
        state = "WARN"
    
    summary = "Command Server is " + _OPER_STATE_MAP[oper_state]
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
