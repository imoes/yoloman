def main(ctx, params):
    # discovery mode: enumerate temperature sensors via SNMP
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.7244.1.2.1.3.4.1"
        
        # Fetch all relevant OIDs in one walk
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid
        ], mutates=False)
        
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse the flat OID list into structured sensor data
        lines = res.stdout.splitlines()
        data = {}
        for line in lines:
            eq_idx = line.find(" = ")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            value_part = line[eq_idx + 3:].strip()
            if not oid_part.startswith(base_oid + "."):
                continue
            tail = oid_part[len(base_oid) + 1:]
            parts = tail.split(".")
            if len(parts) != 2:
                continue
            idx_str, sub_oid = parts
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            data.setdefault(idx, {})
            if sub_oid == "1":
                data[idx]["index"] = value_part
            elif sub_oid == "2":
                data[idx]["status"] = value_part
            elif sub_oid == "3":
                data[idx]["name"] = value_part.replace("\x01", "")
            elif sub_oid == "4":
                data[idx]["value"] = value_part
            elif sub_oid == "6":
                data[idx]["upper_crit"] = value_part
            elif sub_oid == "7":
                data[idx]["upper_warn"] = value_part
            elif sub_oid == "8":
                data[idx]["lower_warn"] = value_part
            elif sub_oid == "9":
                data[idx]["lower_crit"] = value_part
        
        # Build discovery items: one per unique name
        items = []
        seen_names = set()
        for idx in sorted(data.keys()):
            entry = data[idx]
            name = entry.get("name")
            if not name or name in seen_names:
                continue
            seen_names.add(name)
            items.append({
                "item": name,
                "params": {},
                "metrics": ["temperature"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: verify one temperature sensor by name
    item = params.get("item", "")
    if not item:
        fail("item is required")
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.7244.1.2.1.3.4.1"
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid
    ], mutates=False)
    
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    
    lines = res.stdout.splitlines()
    data = {}
    for line in lines:
        eq_idx = line.find(" = ")
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx].strip()
        value_part = line[eq_idx + 3:].strip()
        if not oid_part.startswith(base_oid + "."):
            continue
        tail = oid_part[len(base_oid) + 1:]
        parts = tail.split(".")
        if len(parts) != 2:
            continue
        idx_str, sub_oid = parts
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)
        data.setdefault(idx, {})
        if sub_oid == "3":
            data[idx]["name"] = value_part.replace("\x01", "")
        elif sub_oid == "4":
            data[idx]["value"] = value_part
        elif sub_oid == "6":
            data[idx]["upper_crit"] = value_part
        elif sub_oid == "7":
            data[idx]["upper_warn"] = value_part
        elif sub_oid == "8":
            data[idx]["lower_warn"] = value_part
        elif sub_oid == "9":
            data[idx]["lower_crit"] = value_part
        elif sub_oid == "2":
            data[idx]["status"] = value_part
    
    sensor_entry = None
    for idx in data:
        if data[idx].get("name") == item:
            sensor_entry = data[idx]
            break
    
    if not sensor_entry:
        return {
            "changed": False,
            "msg": "sensor '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    status_map = {
        "1": ("WARN", "other"),
        "2": ("UNKNOWN", "unknown"),
        "3": ("OK", "OK"),
        "4": ("WARN", "non critical upper"),
        "5": ("CRIT", "critical upper"),
        "6": ("CRIT", "non recoverable upper"),
        "7": ("WARN", "non critical lower"),
        "8": ("CRIT", "critical lower"),
        "9": ("CRIT", "non recoverable lower"),
        "10": ("CRIT", "failed"),
    }
    dev_status_str = sensor_entry.get("status", "2")
    dev_status, dev_status_name = status_map.get(dev_status_str, ("UNKNOWN", "unknown[" + dev_status_str + "]"))
    
    value_str = sensor_entry.get("value", "-99")
    reading = float(value_str) if value_str != "-99" else None
    
    if value_str == "-99" or value_str == "":
        return {
            "changed": False,
            "msg": "Status: " + dev_status_name,
            "data": {"state": dev_status, "metrics": {}, "details": ""}
        }
    
    def _validate_levels(dev_warn, dev_crit):
        crit = None
        if dev_crit and dev_crit != "-99":
            if dev_crit.replace(".", "", 1).lstrip("-").isdigit():
                crit = float(dev_crit)
        warn = None
        if dev_warn and dev_warn != "-99":
            if dev_warn.replace(".", "", 1).lstrip("-").isdigit():
                warn = float(dev_warn)
        elif crit != None:
            warn = crit
        return warn, crit
    
    upper_warn, upper_crit = _validate_levels(sensor_entry.get("upper_warn", "-99"), sensor_entry.get("upper_crit", "-99"))
    lower_warn, lower_crit = _validate_levels(sensor_entry.get("lower_warn", "-99"), sensor_entry.get("lower_crit", "-99"))
    
    state = dev_status
    if dev_status == "OK":
        if upper_crit != None and reading >= upper_crit:
            state = "CRIT"
        elif upper_warn != None and reading >= upper_warn:
            state = "WARN"
        elif lower_crit != None and reading <= lower_crit:
            state = "CRIT"
        elif lower_warn != None and reading <= lower_warn:
            state = "WARN"
    
    msg = "Temperature: %f°C, Status: %s" % (reading, dev_status_name)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": reading},
            "details": ""
        }
    }