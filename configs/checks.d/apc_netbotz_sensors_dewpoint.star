def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid_v2 = ".1.3.6.1.4.1.5528.100.4.1.3.1"
        base_oid_50 = ".1.3.6.1.4.1.52674.500.4.1.3.1"
        
        out = []
        
        for base_oid in [base_oid_v2, base_oid_50]:
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On",
                host, base_oid + ".7"
            ], mutates=False)
            
            for line in res.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.strip().split(" = ")
                if len(parts) < 2:
                    continue
                full_oid = parts[0].strip()
                value_part = parts[1].strip()
                instance_id = full_oid.rsplit(".", 1)[-1]
                
                raw_value = ""
                colon_pos = value_part.find(":")
                if colon_pos >= 0:
                    raw_value = value_part[colon_pos + 1:].strip()
                
                reading = None
                if raw_value:
                    # Guard instead of try/except
                    if raw_value.replace(".", "", 1).replace("-", "", 1).isdigit() or (raw_value.count(".") == 1 and raw_value.replace(".", "").replace("-", "", 1).isdigit()):
                        reading = float(raw_value) / 10.0
                
                label = ""
                label_res = ctx.run([
                    "snmpwalk", "-v2c", "-c", community, "-On",
                    host, base_oid + ".1." + instance_id
                ], mutates=False)
                
                for ll in label_res.stdout.splitlines():
                    if ll.strip() and ll.strip().startswith(base_oid + ".1." + instance_id):
                        lp = ll.strip().split(" = ")
                        if len(lp) >= 2:
                            label_raw = lp[1].strip()
                            colon_pos = label_raw.find(":")
                            if colon_pos >= 0:
                                label = label_raw[colon_pos + 1:].strip().strip('"')
                        break
                
                plugged_in = False
                state_res = ctx.run([
                    "snmpwalk", "-v2c", "-c", community, "-On",
                    host, base_oid + ".2." + instance_id
                ], mutates=False)
                
                for sl in state_res.stdout.splitlines():
                    if sl.strip() and sl.strip().startswith(base_oid + ".2." + instance_id):
                        sp = sl.strip().split(" = ")
                        if len(sp) >= 2:
                            sv_raw = sp[1].strip()
                            colon_pos = sv_raw.find(":")
                            if colon_pos >= 0:
                                sv = sv_raw[colon_pos + 1:].strip()
                                if sv.isdigit():
                                    if int(sv) == 1:
                                        plugged_in = True
                        break
                
                if not plugged_in:
                    continue
                
                out.append({
                    "item": instance_id,
                    "params": {"levels": (18.0, 25.0), "levels_lower": (-4.0, -6.0)},
                    "metrics": ["dewpoint"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d dewpoint sensors" % len(out),
            "data": {"discovery": out}
        }
    
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    for base_oid in [".1.3.6.1.4.1.5528.100.4.1.3.1", ".1.3.6.1.4.1.52674.500.4.1.3.1"]:
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid + ".7." + item
        ], mutates=False)
        
        reading = None
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_end = "." + item + ".7"
            if parts[0].strip().endswith(oid_end):
                value_part = parts[1].strip()
                colon_pos = value_part.find(":")
                if colon_pos >= 0:
                    raw_value = value_part[colon_pos + 1:].strip()
                    if raw_value:
                        # Guard instead of try/except
                        if raw_value.replace(".", "", 1).replace("-", "", 1).isdigit() or (raw_value.count(".") == 1 and raw_value.replace(".", "").replace("-", "", 1).isdigit()):
                            reading = float(raw_value) / 10.0
                break
        
        if reading != None:
            label = ""
            label_res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On",
                host, base_oid + ".1." + item
            ], mutates=False)
            
            for ll in label_res.stdout.splitlines():
                if ll.strip() and ll.strip().startswith(base_oid + ".1." + item):
                    lp = ll.strip().split(" = ")
                    if len(lp) >= 2:
                        label_raw = lp[1].strip()
                        colon_pos = label_raw.find(":")
                        if colon_pos >= 0:
                            label = label_raw[colon_pos + 1:].strip().strip('"')
                    break
            
            plugged_in = False
            state_res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On",
                host, base_oid + ".2." + item
            ], mutates=False)
            
            for sl in state_res.stdout.splitlines():
                if sl.strip() and sl.strip().startswith(base_oid + ".2." + item):
                    sp = sl.strip().split(" = ")
                    if len(sp) >= 2:
                        sv_raw = sp[1].strip()
                        colon_pos = sv_raw.find(":")
                        if colon_pos >= 0:
                            sv = sv_raw[colon_pos + 1:].strip()
                            if sv.isdigit():
                                if int(sv) == 1:
                                    plugged_in = True
                    break
            
            if not plugged_in:
                return {
                    "changed": False,
                    "msg": "sensor unplugged",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            
            levels_warn = 18.0
            levels_crit = 25.0
            levels_lower_warn = -4.0
            levels_lower_crit = -6.0
            if params.get("levels") != None:
                levels_warn = params.get("levels")[0]
                levels_crit = params.get("levels")[1]
            if params.get("levels_lower") != None:
                levels_lower_warn = params.get("levels_lower")[0]
                levels_lower_crit = params.get("levels_lower")[1]
            
            state = "OK"
            if reading >= levels_crit or reading <= levels_lower_crit:
                state = "CRIT"
            elif reading >= levels_warn or reading <= levels_lower_warn:
                state = "WARN"
            
            return {
                "changed": False,
                "msg": "Dew point: %f C" % reading + ("" if not label else ", Label: " + label),
                "data": {
                    "state": state,
                    "metrics": {"dewpoint": reading},
                    "details": ""
                }
            }
    
    return {
        "changed": False,
        "msg": "dewpoint sensor not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }