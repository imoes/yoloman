def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        use_desc = params.get("use_sensor_description", False)
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.9"
        ], mutates=False)
        
        instances = {}
        for line in res.stdout.splitlines():
            if not line or "=" not in line:
                continue
            oid_part, value_part = line.split("=", 1)
            oid = oid_part.strip()
            value = value_part.strip().lstrip(" ")
            parts = oid.split(".")
            if len(parts) < 15:
                continue
            leaf_str = parts[-1]
            idx_str = parts[-2]
            if not leaf_str.isdigit() or not idx_str.isdigit():
                continue
            leaf = int(leaf_str)
            idx = int(idx_str)
            
            val = None
            if value.startswith("STRING: "):
                val = value[8:].strip().strip('"')
            elif value.startswith("INTEGER: "):
                if value[9:].isdigit():
                    val = int(value[9:])
                else:
                    continue
            else:
                continue
            
            if idx not in instances:
                instances[idx] = {"DescName": "", "Location": ""}
            
            if leaf == 10:
                instances[idx]["DescName"] = val
            elif leaf == 2:
                instances[idx]["Location"] = val
        
        out = []
        for idx, sensor in sorted(instances.items()):
            if use_desc:
                item_name = "%s-%d %s" % (sensor["Location"], idx, sensor["DescName"])
            else:
                item_name = str(idx)
            out.append({
                "item": item_name,
                "params": {"_item_key": str(idx)},
                "metrics": ["status", "delay"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d leakage sensors" % len(out),
            "data": {"discovery": out}
        }
    
    # ===== CHECK MODE =====
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    sensor_id = str(params.get("_item_key", item))
    if params.get("_item_key") == None and not sensor_id.isdigit():
        parts = item.split("-")
        if len(parts) > 1 and parts[-2].isdigit():
            sensor_id = parts[-2]
        else:
            for part in reversed(item.split()):
                if part.isdigit():
                    sensor_id = part
                    break
    
    status_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.9.%s.8" % sensor_id
    delay_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.9.%s.15" % sensor_id
    
    res_status = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, status_oid
    ], mutates=False)
    
    res_delay = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, delay_oid
    ], mutates=False)
    
    status_val = None
    for line in res_status.stdout.splitlines():
        if line and "=" in line:
            value = line.split("=", 1)[1].strip().lstrip(" ")
            if value.startswith("INTEGER: "):
                status_val = value[9:]
            elif value.startswith("STRING: "):
                status_val = value[8:].strip().strip('"')
    
    delay_val = ""
    for line in res_delay.stdout.splitlines():
        if line and "=" in line:
            value = line.split("=", 1)[1].strip().lstrip(" ")
            if value.startswith("INTEGER: "):
                delay_val = value[9:]
            elif value.startswith("STRING: "):
                delay_val = value[8:].strip().strip('"')
    
    if status_val == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    status_text = status_val
    if status_val == "4":
        status_text = "OK"
    elif status_val == "5":
        status_text = "Alarm"
    elif status_val == "24":
        status_text = "Probe Open"
    elif status_val == "1":
        status_text = "Not Available"
    
    state = "CRIT" if status_text != "OK" else "OK"
    msg = "Status: %s, Delay: %s" % (status_text, delay_val if delay_val else "unknown")
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }