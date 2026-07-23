def main(ctx, params):
    # Discovery mode: enumerate temperature sensors
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.19746.1.1.2.1.1.1"
        ], mutates=False)
        
        base_oid = ".1.3.6.1.4.1.19746.1.1.2.1.1.1"
        sensors = {}
        
        lines = res.stdout.splitlines()
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            
            if not oid_part.startswith(base_oid + "."):
                continue
            
            rest = oid_part[len(base_oid) + 1:]
            if "." not in rest:
                continue
            field_str, idx_str = rest.split(".", 1)
            
            # Guard-based parsing instead of try/except
            if not field_str.isdigit() or not idx_str.isdigit():
                continue
            
            field = int(field_str)
            idx = int(idx_str)
            
            if val_part.startswith("STRING: "):
                val = val_part[8:].strip('"')
            elif val_part.startswith("INTEGER: "):
                val = val_part[9:]
            else:
                val = val_part
            
            if idx not in sensors:
                sensors[idx] = {}
            
            if field == 1:
                sensors[idx]["encid"] = val
            elif field == 2:
                sensors[idx]["index"] = val
            elif field == 4:
                sensors[idx]["descr"] = val
            elif field == 5:
                sensors[idx]["reading"] = val
            elif field == 6:
                sensors[idx]["status"] = val
        
        out = []
        for idx, sens in sensors.items():
            status = sens.get("status", "")
            if status == "2":
                continue
            
            encid = sens.get("encid", "")
            index = sens.get("index", "")
            descr = sens.get("descr", "")
            
            item = descr + " Enclosure " + encid if descr else encid + "-" + index
            
            out.append({
                "item": item,
                "params": {},
                "metrics": ["temp"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode: evaluate one sensor item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.19746.1.1.2.1.1.1"
    ], mutates=False)
    
    base_oid = ".1.3.6.1.4.1.19746.1.1.2.1.1.1"
    sensors = {}
    
    lines = res.stdout.splitlines()
    for line in lines:
        if not line.strip():
            continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            
            if not oid_part.startswith(base_oid + "."):
                continue
            
            rest = oid_part[len(base_oid) + 1:]
            if "." not in rest:
                continue
            field_str, idx_str = rest.split(".", 1)
            
            # Guard-based parsing instead of try/except
            if not field_str.isdigit() or not idx_str.isdigit():
                continue
            
            field = int(field_str)
            idx = int(idx_str)
            
            if val_part.startswith("STRING: "):
                val = val_part[8:].strip('"')
            elif val_part.startswith("INTEGER: "):
                val = val_part[9:]
            else:
                val = val_part
            
            if idx not in sensors:
                sensors[idx] = {}
            
            if field == 1:
                sensors[idx]["encid"] = val
            elif field == 2:
                sensors[idx]["index"] = val
            elif field == 4:
                sensors[idx]["descr"] = val
            elif field == 5:
                sensors[idx]["reading"] = val
            elif field == 6:
                sensors[idx]["status"] = val
    
    matched = False
    for idx, sens in sensors.items():
        status = sens.get("status", "")
        if status == "2":
            continue
        
        encid = sens.get("encid", "")
        index = sens.get("index", "")
        descr = sens.get("descr", "")
        
        check_item = descr + " Enclosure " + encid if descr else encid + "-" + index
        
        if item == check_item:
            matched = True
            
            status_val = status
            dev_status = 0
            state_name = "OK"
            if status_val == "0":
                dev_status = 2
                state_name = "Failed"
            elif status_val == "1":
                dev_status = 0
                state_name = "OK"
            elif status_val == "3":
                dev_status = 1
                state_name = "Overheat Warning"
            elif status_val == "4":
                dev_status = 2
                state_name = "Overheat Critical"
            
            reading_str = sens.get("reading", "0")
            if not reading_str:
                reading = 0.0
            elif reading_str.isdigit():
                reading = float(reading_str) / 10.0
            else:
                reading = 0.0
            
            warn = params.get("levels", (0, 0))
            crit = params.get("levels_upper", (0, 0))
            
            warn_upper = 80
            crit_upper = 90
            if len(warn) > 1 and warn[1] != 0:
                warn_upper = warn[1]
            if len(crit) > 1 and crit[1] != 0:
                crit_upper = crit[1]
            
            state = "OK"
            if reading >= crit_upper:
                state = "CRIT"
            elif reading >= warn_upper:
                state = "WARN"
            
            return {
                "changed": False,
                "msg": "Temperature: %s C, Status: %s" % (str(reading), state_name),
                "data": {
                    "state": state,
                    "metrics": {"temp": reading},
                    "details": state_name
                }
            }
    
    return {
        "changed": False,
        "msg": "temperature sensor not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }