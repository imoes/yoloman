def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.3.51.3.1.2.2.1.2"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 2:
                oid_part = parts[0].strip()
                value_part = " ".join(parts[2:]).strip().strip('"')
                if value_part and oid_part.endswith(".2."):
                    items.append({"item": value_part, "params": {}, "metrics": ["volt"]})
        
        return {"changed": False, "msg": "discovered %d voltage sensors" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2.3.51.3.1.2.2.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    sensors = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid = parts[0].strip()
        value = " ".join(parts[2:]).strip().strip('"')
        
        base = ".1.3.6.1.4.1.2.3.51.3.1.2.2.1"
        if not oid.startswith(base + "."):
            continue
        suffix_oid = oid[len(base)+1:]
        parts_oid = suffix_oid.split(".")
        if len(parts_oid) < 2:
            continue
        suffix = parts_oid[0]
        index_str = parts_oid[1]
        index = int(index_str) if index_str.isdigit() else 0
        
        if index not in sensors:
            sensors[index] = {}
        if suffix == "2":
            sensors[index]["label"] = value
        elif suffix == "3":
            sensors[index]["value_raw"] = int(value) if value.isdigit() else 0
        elif suffix == "6":
            sensors[index]["warn_raw"] = int(value) if value.isdigit() else 0
        elif suffix == "7":
            sensors[index]["crit_raw"] = int(value) if value.isdigit() else 0
        elif suffix == "9":
            sensors[index]["warn_low_raw"] = int(value) if value.isdigit() else 0
        elif suffix == "10":
            sensors[index]["crit_low_raw"] = int(value) if value.isdigit() else 0
    
    for idx, sensor in sensors.items():
        if sensor.get("label") == item:
            volt = float(sensor.get("value_raw", 0)) / 1000.0
            warn = float(sensor.get("warn_raw", 0)) / 1000.0
            crit = float(sensor.get("crit_raw", 0)) / 1000.0
            warn_low = float(sensor.get("warn_low_raw", 0)) / 1000.0
            crit_low = float(sensor.get("crit_low_raw", 0)) / 1000.0
            
            state = "OK"
            if volt >= crit or volt <= crit_low:
                state = "CRIT"
            elif volt >= warn or volt <= warn_low:
                state = "WARN"
            
            details = "Volt: %f" % volt
            return {"changed": False, "msg": details,
                    "data": {"state": state, "metrics": {"volt": volt}, "details": details}}
    
    return {"changed": False, "msg": "voltage sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}