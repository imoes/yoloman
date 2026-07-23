# ===== constants =====
_TRANSLATE_SPEED = {
    "0": ("WARN", "stop"),
    "1": ("OK", "low"),
    "2": ("OK", "mid-low"),
    "3": ("OK", "mid"),
    "4": ("OK", "mid-high"),
    "5": ("WARN", "high"),
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2011.2.25.4.70.20.10.10.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse OID lines: ".1.3.6.1.4.1.2011.2.25.4.70.20.10.10.1.1 = STRING: \"value\""
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Split on first "=" to separate OID from value
            parts = line.strip().split("=", 1)
            if len(parts) != 2:
                continue
            # Extract value - handle quoted strings
            value_str = parts[1].strip()
            if value_str.startswith('"') and value_str.endswith('"'):
                value = value_str[1:-1]
            else:
                value = value_str.strip()
            
            # The fan name is the first OID index (second to last component)
            oid_path = parts[0].strip()
            oid_parts = oid_path.rsplit(".", 1)
            if len(oid_parts) != 2:
                continue
            fan_name = oid_parts[1]
            
            items.append({
                "item": fan_name,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.2011.2.25.4.70.20.10.10.1." + item
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "fan " + item + " not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse snmpget output: OID = STRING: "value"
    line = res.stdout.strip()
    parts = line.split("=", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "unable to parse SNMP output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value_str = parts[1].strip()
    if value_str.startswith('"') and value_str.endswith('"'):
        speed_val = value_str[1:-1]
    else:
        speed_val = value_str.strip()
    
    # Map speed value
    if speed_val in _TRANSLATE_SPEED:
        state_str, readable = _TRANSLATE_SPEED[speed_val]
        state = "CRIT" if state_str == "WARN" else state_str
    else:
        state = "UNKNOWN"
        readable = "unknown"
    
    return {
        "changed": False,
        "msg": "Speed: " + readable,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }