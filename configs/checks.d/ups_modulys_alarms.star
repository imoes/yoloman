# ===== Constants for alarm definitions =====
OIDDEF = {
    "1": {"state": "CRIT", "summary": "Disconnect"},
    "2": {"state": "CRIT", "summary": "Input power failure"},
    "3": {"state": "CRIT", "summary": "Low batteries"},
    "4": {"state": "WARN", "summary": "High load"},
    "5": {"state": "CRIT", "summary": "Severley high load"},
    "6": {"state": "CRIT", "summary": "On bypass"},
    "7": {"state": "CRIT", "summary": "General failure"},
    "8": {"state": "CRIT", "summary": "Battery ground fault"},
    "9": {"state": "OK", "summary": "UPS test in progress"},
    "10": {"state": "CRIT", "summary": "UPS test failure"},
    "11": {"state": "CRIT", "summary": "Fuse failure"},
    "12": {"state": "CRIT", "summary": "Output overload"},
    "13": {"state": "CRIT", "summary": "Output overcurrent"},
    "14": {"state": "CRIT", "summary": "Inverter abnormal"},
    "15": {"state": "CRIT", "summary": "Rectifier abnormal"},
    "16": {"state": "CRIT", "summary": "Reserve abnormal"},
    "17": {"state": "WARN", "summary": "On reserve"},
    "18": {"state": "CRIT", "summary": "Overheating"},
    "19": {"state": "CRIT", "summary": "Output abnormal"},
    "20": {"state": "CRIT", "summary": "Bypass bad"},
    "21": {"state": "OK", "summary": "In standby mode"},
    "22": {"state": "CRIT", "summary": "Charger failure"},
    "23": {"state": "CRIT", "summary": "Fan failure"},
    "24": {"state": "OK", "summary": "In economic mode"},
    "25": {"state": "WARN", "summary": "Output turned off"},
    "26": {"state": "WARN", "summary": "Smart shutdown in progress"},
    "27": {"state": "CRIT", "summary": "Emergency power off"},
    "28": {"state": "WARN", "summary": "Shutdown"},
    "29": {"state": "CRIT", "summary": "Output breaker open"},
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.2254.2.4", "9"], mutates=False)
        # Check if any data is present by probing the OID tree
        if not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    
    # Check mode (single service)
    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.2254.2.4", "9"], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []
    
    # Parse snmpwalk output: each line is "oid.oidend value"
    found_any = False
    result_lines = []
    state_crit = False
    state_warn = False
    
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oidend = parts[0].rsplit(".", 1)[-1]
        flag = parts[1]
        
        # Only process if flag is a non-zero integer and not "NULL"
        if flag != "NULL" and flag.isdigit() and int(flag) != 0:
            found_any = True
            alarm = OIDDEF.get(oidend, {"state": "UNKNOWN", "summary": "Unknown alarm"})
            result_lines.append(alarm["summary"])
            if alarm["state"] == "CRIT":
                state_crit = True
            elif alarm["state"] == "WARN":
                state_warn = True
    
    # Determine overall state
    if not found_any:
        state = "OK"
        msg = "No alarms"
        details = ""
    else:
        # Checkmk style: CRIT takes precedence over WARN over OK
        if state_crit:
            state = "CRIT"
        elif state_warn:
            state = "WARN"
        else:
            state = "OK"
        msg = ", ".join(result_lines) if result_lines else "Alarms detected"
        details = ""
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }
