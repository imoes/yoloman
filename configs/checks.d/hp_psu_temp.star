# hp_psu_temp starlark check module
# Reads HP PSU temperature data via SNMP and reports temperature status

_HP_PSU_STATE_MAP = {
    "1": ("CRIT", "Not present"),
    "2": ("CRIT", "Not plugged"),
    "3": ("OK", "Powered"),
    "4": ("WARN", "Failed"),
    "5": ("CRIT", "Permanent Failure"),
    "6": ("UNKNOWN", "Max"),
    "8": ("CRIT", "Unplugged"),
    "9": ("CRIT", "Aux not powered"),
}

def _parse_snmp_line(line):
    """Parse a snmpwalk output line into (oid_end, status, temp_str)."""
    if line.find(" = ") == -1:
        return None
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return None
    oid_part = parts[0]
    value_part = parts[1]
    
    base_oid = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1."
    if not oid_part.startswith(base_oid):
        return None
    index = oid_part[len(base_oid):]
    
    if value_part.startswith("STRING: "):
        value_str = value_part[len("STRING: "):]
    else:
        value_str = value_part.strip().strip('"')
    
    fields = value_str.split(",")
    if len(fields) < 2:
        return None
    
    status = fields[0].strip()
    temp_str = fields[1].strip()
    
    return (index, status, temp_str)

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            if line.strip() == "":
                continue
            parsed = _parse_snmp_line(line)
            if parsed != None:
                index, status, temp_str = parsed
                items.append({
                    "item": index,
                    "params": {"levels": (70.0, 80.0)},
                    "metrics": ["temp"]
                })
        
        return {"changed": False, "msg": "discovered %d PSUs" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1." + str(item)
    ], mutates=False)
    
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "PSU not found: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parsed = _parse_snmp_line(res.stdout.strip())
    if parsed == None:
        return {"changed": False, "msg": "Could not parse SNMP response for PSU " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    index, status, temp_str = parsed
    
    temp = 0.0
    if temp_str.isdigit():
        temp = float(temp_str)
    
    if status == "8" and temp == 0.0:
        return {"changed": False, "msg": "No temperature data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    levels = params.get("levels", (70.0, 80.0))
    warn = levels[0]
    crit = levels[1]
    
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    status_desc = _HP_PSU_STATE_MAP.get(status, ("UNKNOWN", "Unknown status code sent by device"))
    status_state = status_desc[0]
    status_msg = status_desc[1]
    
    if state == "OK" and status_state == "WARN":
        state = "WARN"
    elif state in ["OK", "WARN"] and status_state == "CRIT":
        state = "CRIT"
    elif state in ["OK", "WARN", "CRIT"] and status_state == "UNKNOWN":
        state = "UNKNOWN"
    
    msg = "Temperature: %f C, Status: %s" % (temp, status_msg)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temp": temp}, "details": ""}}