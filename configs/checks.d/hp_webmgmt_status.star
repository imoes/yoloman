def main(ctx, params):
    _STATUS_MAP = {
        "1": ("UNKNOWN", "unknown"),
        "2": ("UNKNOWN", "unused"),
        "3": ("OK", "ok"),
        "4": ("WARN", "warning"),
        "5": ("CRIT", "critical"),
        "6": ("CRIT", "non-recoverable"),
    }

    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.11.2.36.1.1.5.1.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_path = parts[0].strip()
            value = parts[1].strip()
            if ": " in value:
                value = value.split(": ", 1)[-1].strip()
            
            oid_parts = oid_path.split(".")
            if len(oid_parts) >= 2:
                last_part = oid_parts[-1]
                idx = int(last_part) if last_part.isdigit() else 0
                items.append({"item": str(idx), "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.11.2.36.1.1.5.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res_model = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.9.1"
    ], mutates=False)
    device_model = ""
    if res_model.rc == 0 and res_model.stdout.strip():
        parts = res_model.stdout.strip().split(" = ")
        if len(parts) >= 2:
            value_part = parts[1].strip()
            if ": " in value_part:
                device_model = value_part.split(": ", 1)[-1].strip()
    
    res_serial = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.10.1"
    ], mutates=False)
    serial_number = ""
    if res_serial.rc == 0 and res_serial.stdout.strip():
        parts = res_serial.stdout.strip().split(" = ")
        if len(parts) >= 2:
            value_part = parts[1].strip()
            if ": " in value_part:
                serial_number = value_part.split(": ", 1)[-1].strip()
    
    state = "UNKNOWN"
    status_msg = "unknown"
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_path = parts[0].strip()
        value = parts[1].strip()
        if ": " in value:
            value = value.split(": ", 1)[-1].strip()
        
        oid_parts = oid_path.split(".")
        if len(oid_parts) >= 2:
            last_part = oid_parts[-1]
            if last_part.isdigit():
                idx = int(last_part)
                if str(idx) == item:
                    status_code = value
                    if status_code in _STATUS_MAP:
                        state, status_msg = _STATUS_MAP[status_code]
                    else:
                        state, status_msg = "UNKNOWN", "unknown"
                    break
    
    summary = "Device status: %s" % status_msg
    if device_model and serial_number:
        summary += " [Model: %s, Serial Number: %s]" % (device_model, serial_number)
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}