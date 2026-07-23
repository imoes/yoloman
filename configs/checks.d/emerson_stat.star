def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.6302.2.1.2.1.0"
        ], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # Check detection condition: .1.3.6.1.4.1.6302.2.1.1.1.0 == "Emerson Network Power"
        detect_res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.6302.2.1.1.1.0"
        ], mutates=False)
        if detect_res.rc != 0 or not detect_res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # Parse snmpget response: OID = Type: Value
        line = detect_res.stdout.strip()
        parts = line.split(" = ")
        if len(parts) != 2:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        value = parts[1].strip() if parts[1].strip() else ""
        if not value.startswith('"Emerson Network Power"') and value != "Emerson Network Power":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # Device matches - one service
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    
    # Check mode
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.6302.2.1.2.1.0"
    ], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "Status: unknown (no data)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP response: OID = Type: Value
    line = res.stdout.strip()
    parts = line.split(" = ")
    if len(parts) != 2:
        return {"changed": False, "msg": "Status: unknown (parse error)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_str = parts[1].strip()
    # Extract integer value - remove quotes if present
    if value_str.startswith('"') and value_str.endswith('"'):
        value_str = value_str[1:-1]
    if not value_str.isdigit():
        return {"changed": False, "msg": "Status: unknown (invalid value)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status = int(value_str)
    status_text = {
        1: "unknown",
        2: "normal",
        3: "observation",
        4: "warning - A3",
        5: "minor - MA",
        6: "major - CA",
        7: "unmanaged",
        8: "restricted",
        9: "testing",
        10: "disabled",
    }
    infotext = "Status: " + status_text.get(status, "unknown")
    
    if status in [5, 6, 10]:
        state = "CRIT"
    elif status in [1, 3, 4, 7, 8, 9]:
        state = "WARN"
    elif status in [2]:
        state = "OK"
    else:
        state = "UNKNOWN"
    
    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": {}, "details": ""}}
