def main(ctx, params):
    if params.get("_discover"):
        base_oids = [".1.3.6.1.4.1.2606.4.2.3.5.2.1", ".1.3.6.1.4.1.2606.4.2.4.5.2.1",
                     ".1.3.6.1.4.1.2606.4.2.5.5.2.1", ".1.3.6.1.4.1.2606.4.2.6.5.2.1"]
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        indices = []
        
        # First, fetch all indices from the first subtree's index OID
        index_oid = base_oids[0] + ".1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, index_oid], mutates=False)
        if res.rc == 0:
            for line in res.stdout.splitlines():
                if "=" in line:
                    oid_part, value_part = line.split("=", 1)
                    oid_parts = oid_part.strip().split(".")
                    if len(oid_parts) >= 12:
                        idx_str = oid_parts[-1]
                        if idx_str.isdigit():
                            indices.append(int(idx_str))
        
        sensor_map = {}
        # For each subtree and index, fetch all required OIDs
        for tree_idx, base_oid in zip(("3", "4", "5", "6"), base_oids):
            for idx in indices:
                # Fetch description
                desc_oid = base_oid + "." + str(idx) + ".3"
                res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, desc_oid], mutates=False)
                if res.rc != 0 or "=" not in res.stdout:
                    continue
                _, value = res.stdout.strip().split("=", 1)
                value = value.strip()
                if value.startswith("STRING: "):
                    desc = value[8:].strip('"')
                else:
                    continue
                
                # Fetch status
                status_oid = base_oid + "." + str(idx) + ".4"
                res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, status_oid], mutates=False)
                if res.rc != 0 or "=" not in res.stdout:
                    continue
                _, value = res.stdout.strip().split("=", 1)
                value = value.strip()
                if value.startswith("INTEGER: "):
                    status_str = value[9:]
                    if status_str.lstrip("-").isdigit():
                        status = int(status_str)
                    else:
                        continue
                else:
                    continue
                
                # Fetch value
                value_oid = base_oid + "." + str(idx) + ".5"
                res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, value_oid], mutates=False)
                if res.rc != 0 or "=" not in res.stdout:
                    continue
                _, value = res.stdout.strip().split("=", 1)
                value = value.strip()
                if value.startswith("INTEGER: "):
                    value_str = value[9:]
                    if value_str.lstrip("-").isdigit():
                        raw_value = int(value_str)
                    else:
                        continue
                else:
                    continue
                
                # Fetch type
                type_oid = base_oid + "." + str(idx) + ".2"
                res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, type_oid], mutates=False)
                if res.rc != 0 or "=" not in res.stdout:
                    continue
                _, value = res.stdout.strip().split("=", 1)
                value = value.strip()
                if value.startswith("INTEGER: "):
                    type_str = value[9:]
                    if type_str.lstrip("-").isdigit():
                        type_ = int(type_str)
                    else:
                        continue
                else:
                    continue
                
                # Map type to unit
                unit_map = {72: "kW", 73: "kW", 74: "Hz", 75: "V", 77: "A", 79: "kW", 80: "kW"}
                unit = unit_map.get(type_, "")
                reading = float(raw_value) / 10.0
                
                item_name = desc + " " + tree_idx + "." + str(idx)
                sensor_map[item_name] = {"status": status, "unit": unit, "reading": reading, "description": desc}
        
        discovery = []
        for item_name in sensor_map:
            discovery.append({
                "item": item_name,
                "params": {},
                "metrics": [sensor_map[item_name]["unit"]]
            })
        
        return {"changed": False, "msg": "discovered %d sensors" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract tree and sensor index from item
    parts = item.split()
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    tree_sensor = parts[-1]
    if tree_sensor.find(".") == -1:
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    idx_pos = tree_sensor.rfind(".")
    if idx_pos == -1:
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    tree_idx = tree_sensor[:idx_pos]
    sensor_idx = tree_sensor[idx_pos+1:]
    
    if not tree_idx.isdigit() or not sensor_idx.isdigit():
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    tree_num = int(tree_idx)
    if tree_num < 3 or tree_num > 6:
        return {"changed": False, "msg": "invalid tree index",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    base_oid = base_oids[tree_num - 3]
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch status
    status_oid = base_oid + "." + sensor_idx + ".4"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, status_oid], mutates=False)
    if res.rc != 0 or "=" not in res.stdout:
        return {"changed": False, "msg": "sensor not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    _, value = res.stdout.strip().split("=", 1)
    value = value.strip()
    if value.startswith("INTEGER: "):
        status_str = value[9:]
        if status_str.lstrip("-").isdigit():
            status = int(status_str)
        else:
            return {"changed": False, "msg": "could not read status",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "could not read status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch value
    value_oid = base_oid + "." + sensor_idx + ".5"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, value_oid], mutates=False)
    if res.rc != 0 or "=" not in res.stdout:
        return {"changed": False, "msg": "sensor not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    _, value = res.stdout.strip().split("=", 1)
    value = value.strip()
    if value.startswith("INTEGER: "):
        value_str = value[9:]
        if value_str.lstrip("-").isdigit():
            raw_value = int(value_str)
        else:
            return {"changed": False, "msg": "could not read value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "could not read value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch type
    type_oid = base_oid + "." + sensor_idx + ".2"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, type_oid], mutates=False)
    if res.rc != 0 or "=" not in res.stdout:
        return {"changed": False, "msg": "sensor not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    _, value = res.stdout.strip().split("=", 1)
    value = value.strip()
    if value.startswith("INTEGER: "):
        type_str = value[9:]
        if type_str.lstrip("-").isdigit():
            type_ = int(type_str)
        else:
            return {"changed": False, "msg": "could not read type",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "could not read type",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get description for summary
    desc_oid = base_oid + "." + sensor_idx + ".3"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, desc_oid], mutates=False)
    description = ""
    if res.rc == 0 and "=" in res.stdout:
        _, value = res.stdout.strip().split("=", 1)
        value = value.strip()
        if value.startswith("STRING: "):
            description = value[8:].strip('"')
    
    # Map type to unit
    unit_map = {72: "kW", 73: "kW", 74: "Hz", 75: "V", 77: "A", 79: "kW", 80: "kW"}
    unit = unit_map.get(type_, "")
    reading = float(raw_value) / 10.0
    
    # Determine state: 4 = ok, else critical
    state = "OK" if status == 4 else "CRIT"
    
    # Build summary
    summary = "%s at %s%s" % (description, str(reading), unit)
    
    # Build metrics dict
    metrics = {}
    if unit:
        metrics[unit] = reading
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}