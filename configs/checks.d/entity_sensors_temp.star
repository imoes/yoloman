def main(ctx, params):
    if params.get("_discover"):
        # Discovery: enumerate temperature sensors via SNMP
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.99.1.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        lines = res.stdout.splitlines()
        sensors = {}
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith(".1.3.6.1.2.1.99.1.1.1.2."):
                oid_part = line.split("=")[0].strip()
                sensor_index = oid_part.split(".")[-1]
                value = line.split("=")[1].strip() if "=" in line else ""
                if value == "6" or value == "7":
                    sensors[sensor_index] = {"type": int(value)}
                i += 1
            elif line.startswith(".1.3.6.1.2.1.99.1.1.1.4.") or line.startswith(".1.3.6.1.2.1.99.1.1.1.5.") or line.startswith(".1.3.6.1.2.1.99.1.1.1.6."):
                i += 1
            else:
                i += 1
        
        res_names = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.47.1.1.1.1.7"
        ], mutates=False)
        if res_names.rc != 0:
            fail("SNMP name walk failed: " + res_names.stderr)
        
        name_map = {}
        for line in res_names.stdout.splitlines():
            parts = line.strip().split("=")
            if len(parts) < 2:
                continue
            oid_end = parts[0].strip().split(".")[-1]
            name = parts[1].strip()
            if "Temperature" in name or "temp" in name.lower():
                name_map[oid_end] = name
        
        res_values = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.99.1.1.1.4"
        ], mutates=False)
        if res_values.rc != 0:
            fail("SNMP value walk failed: " + res_values.stderr)
        
        value_map = {}
        for line in res_values.stdout.splitlines():
            parts = line.strip().split("=")
            if len(parts) < 2:
                continue
            oid_end = parts[0].strip().split(".")[-1]
            val = parts[1].strip()
            if val.isdigit():
                value_map[oid_end] = int(val)
        
        out = []
        for idx in name_map:
            type_oid = ".1.3.6.1.2.1.99.1.1.1.2." + idx
            type_line = None
            for line in res.stdout.splitlines():
                if line.strip().startswith(type_oid + " "):
                    type_line = line.strip().split("=")[1].strip()
                    break
            if type_line not in ["6", "7"]:
                continue
            
            if idx not in name_map or "Temperature" not in name_map[idx]:
                continue
            
            if idx not in value_map:
                continue
            
            out.append({"item": name_map[idx], "params": {}, "metrics": ["temp"]})
        
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    
    res_names = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.2.1.47.1.1.1.1.7"
    ], mutates=False)
    if res_names.rc != 0:
        fail("SNMP name walk failed: " + res_names.stderr)
    
    oid_end = ""
    for line in res_names.stdout.splitlines():
        if "Temperature" in line and item in line:
            parts = line.strip().split("=")
            if len(parts) > 0:
                oid_end = parts[0].strip().split(".")[-1]
            break
    
    if oid_end == "":
        return {"changed": False, "msg": "temperature sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res_value = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.2.1.99.1.1.1.4." + oid_end
    ], mutates=False)
    if res_value.rc != 0 or "=" not in res_value.stdout:
        return {"changed": False, "msg": "temperature reading unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_str = res_value.stdout.strip().split("=")[1].strip()
    if not value_str.isdigit():
        return {"changed": False, "msg": "temperature reading not a number",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    reading = int(value_str)
    
    res_scale = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.2.1.99.1.1.1.3." + oid_end
    ], mutates=False)
    if res_scale.rc != 0 or "=" not in res_scale.stdout:
        return {"changed": False, "msg": "sensor scale unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    scale_str = res_scale.stdout.strip().split("=")[1].strip()
    scale = int(scale_str) if scale_str.isdigit() else 1
    
    # Compute actual value: reading / (10^scale) without ** operator
    divisor = 1
    j = 0
    while j < scale:
        divisor = divisor * 10
        j = j + 1
    actual_value = float(reading) / float(divisor)
    
    unit = "C"
    res_type = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.2.1.99.1.1.1.2." + oid_end
    ], mutates=False)
    if res_type.rc == 0:
        type_str = res_type.stdout.strip().split("=")[1].strip()
        if type_str == "7":
            unit = "F"
    
    warn = params.get("warn", None)
    crit = params.get("crit", None)
    if warn != None:
        warn = float(warn)
    if crit != None:
        crit = float(crit)
    
    state = "OK"
    if warn != None and crit != None:
        if actual_value >= crit:
            state = "CRIT"
        elif actual_value >= warn:
            state = "WARN"
    elif warn != None and crit == None:
        if actual_value >= warn:
            state = "WARN"
    elif crit != None and warn == None:
        if actual_value >= crit:
            state = "CRIT"
    
    summary = "Temperature: %f %s" % (actual_value, unit)
    if warn != None:
        summary = summary + ", warn at %f %s" % (warn, unit)
    if crit != None:
        summary = summary + ", crit at %f %s" % (crit, unit)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"temp": actual_value},
            "details": "",
        },
    }