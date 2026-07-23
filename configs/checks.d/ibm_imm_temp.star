def main(ctx, params):
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.2.3.51.3.1.1.2.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        data = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            eq_idx = line.find('=')
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            value_part = line[eq_idx+1:].strip()
            if not oid_part.startswith(base_oid + "."):
                continue
            suffix = oid_part[len(base_oid)+1:]
            if "." not in suffix:
                continue
            parts = suffix.split(".", 1)
            if len(parts) != 2:
                continue
            idx = parts[0]
            type_num = parts[1].split(".")[0] if "." in parts[1] else parts[1]
            value = value_part
            if ":" in value:
                value = value.split(":", 1)[1].strip()
            if idx not in data:
                data[idx] = {"idx": idx}
            data[idx][type_num] = value
        
        discovery = []
        for idx in data:
            temp_str = data[idx].get("3", "")
            temp_val = 0.0
            if temp_str != "":
                stripped = temp_str.replace(".", "", 1)
                if stripped.isdigit():
                    temp_val = float(temp_str)
                elif stripped.startswith("-") and stripped[1:].isdigit():
                    temp_val = float(temp_str)
            if temp_val != 0.0:
                p = {}
                warn_u_str = data[idx].get("6", "")
                crit_u_str = data[idx].get("7", "")
                warn_l_str = data[idx].get("9", "")
                crit_l_str = data[idx].get("10", "")
                warn_u = 0.0
                crit_u = 0.0
                warn_l = 0.0
                crit_l = 0.0
                has_warn_u = warn_u_str != "" and (warn_u_str.replace(".", "", 1).isdigit() or (warn_u_str.startswith("-") and warn_u_str[1:].replace(".", "", 1).isdigit()))
                has_crit_u = crit_u_str != "" and (crit_u_str.replace(".", "", 1).isdigit() or (crit_u_str.startswith("-") and crit_u_str[1:].replace(".", "", 1).isdigit()))
                has_warn_l = warn_l_str != "" and (warn_l_str.replace(".", "", 1).isdigit() or (warn_l_str.startswith("-") and warn_l_str[1:].replace(".", "", 1).isdigit()))
                has_crit_l = crit_l_str != "" and (crit_l_str.replace(".", "", 1).isdigit() or (crit_l_str.startswith("-") and crit_l_str[1:].replace(".", "", 1).isdigit()))
                if has_warn_u:
                    warn_u = float(warn_u_str)
                if has_crit_u:
                    crit_u = float(crit_u_str)
                if has_warn_l:
                    warn_l = float(warn_l_str)
                if has_crit_l:
                    crit_l = float(crit_l_str)
                if has_warn_u and has_crit_u:
                    p["levels"] = (warn_u, crit_u)
                if has_warn_l and has_crit_l:
                    if "levels" in p:
                        p["levels_lower"] = (warn_l, crit_l)
                    else:
                        p["levels_lower"] = (warn_l, crit_l)
                discovery.append({"item": idx, "params": p, "metrics": ["temperature"]})
        
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    base_oid = ".1.3.6.1.4.1.2.3.51.3.1.1.2.1"
    item_oid = base_oid + "." + item
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        item_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP fetch failed for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    data = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        eq_idx = line.find('=')
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx].strip()
        value_part = line[eq_idx+1:].strip()
        if not oid_part.startswith(item_oid + "."):
            continue
        suffix = oid_part[len(item_oid)+1:]
        if "." not in suffix:
            continue
        type_num = suffix.split(".")[0]
        value = value_part
        if ":" in value:
            value = value.split(":", 1)[1].strip()
        data[type_num] = value
    
    temp_str = data.get("3", "")
    temp = 0.0
    is_valid_temp = temp_str != "" and (temp_str.replace(".", "", 1).isdigit() or (temp_str.startswith("-") and temp_str[1:].replace(".", "", 1).isdigit()))
    if is_valid_temp:
        temp = float(temp_str)
    else:
        return {"changed": False, "msg": "invalid temperature for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    warn_u = None
    crit_u = None
    warn_l = None
    crit_l = None
    
    levels = params.get("levels", (None, None))
    if levels != None:
        if len(levels) >= 1 and levels[0] != None:
            warn_u = levels[0]
        if len(levels) >= 2 and levels[1] != None:
            crit_u = levels[1]
    
    levels_lower = params.get("levels_lower", (None, None))
    if levels_lower != None:
        if len(levels_lower) >= 1 and levels_lower[0] != None:
            warn_l = levels_lower[0]
        if len(levels_lower) >= 2 and levels_lower[1] != None:
            crit_l = levels_lower[1]
    
    warn_u_str = data.get("6", "")
    crit_u_str = data.get("7", "")
    warn_l_str = data.get("9", "")
    crit_l_str = data.get("10", "")
    
    if warn_u == None:
        if warn_u_str != "" and (warn_u_str.replace(".", "", 1).isdigit() or (warn_u_str.startswith("-") and warn_u_str[1:].replace(".", "", 1).isdigit())):
            warn_u = float(warn_u_str)
    if crit_u == None:
        if crit_u_str != "" and (crit_u_str.replace(".", "", 1).isdigit() or (crit_u_str.startswith("-") and crit_u_str[1:].replace(".", "", 1).isdigit())):
            crit_u = float(crit_u_str)
    if warn_l == None:
        if warn_l_str != "" and (warn_l_str.replace(".", "", 1).isdigit() or (warn_l_str.startswith("-") and warn_l_str[1:].replace(".", "", 1).isdigit())):
            warn_l = float(warn_l_str)
    if crit_l == None:
        if crit_l_str != "" and (crit_l_str.replace(".", "", 1).isdigit() or (crit_l_str.startswith("-") and crit_l_str[1:].replace(".", "", 1).isdigit())):
            crit_l = float(crit_l_str)
    
    state = "OK"
    msg_parts = []
    msg_parts.append("Temperature: %f" % temp)
    
    if crit_u != None and temp >= crit_u:
        state = "CRIT"
        msg_parts.append("(Crit at %f)" % crit_u)
    elif warn_u != None and temp >= warn_u:
        state = "WARN"
        msg_parts.append("(Warn at %f)" % warn_u)
    
    if crit_l != None and temp <= crit_l:
        state = "CRIT"
        msg_parts.append("(Crit lower at %f)" % crit_l)
    elif warn_l != None and temp <= warn_l:
        state = "WARN"
        msg_parts.append("(Warn lower at %f)" % warn_l)
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }