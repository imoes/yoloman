def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "not installed: snmpget rc=" + str(res.rc), "data": {"discovery": []}}
        
        sys_oid = res.stdout.strip()
        if sys_oid != ".1.3.6.1.4.1.367.1.1":
            return {"changed": False, "msg": "Ricoh printer not detected", "data": {"discovery": []}}
        
        walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.367.3.2.1.2.24.1.1.2"], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "snmpwalk column 2 failed: rc=" + str(walk.rc), "data": {"discovery": []}}
        
        warn_default = 20.0
        crit_default = 10.0
        levels = params.get("levels", (warn_default, crit_default))
        warn = levels[0]
        crit = levels[1]
        
        name_rows = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            value = parts[1]
            idx = oid[len(".1.3.6.1.4.1.367.3.2.1.2.24.1.1.2") + 1:]
            name_rows[idx] = value.strip(' "')
        
        out = []
        for idx in name_rows:
            name_rev = name_rows[idx].split(" ")
            if len(name_rev) == 2:
                name_rev = [name_rev[1], name_rev[0]]
            name = " ".join(name_rev)
            out.append({"item": name, "params": {"levels": (warn, crit)}, "metrics": ["supply_level"]})
        
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "not installed: snmpget rc=" + str(res.rc), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    sys_oid = res.stdout.strip()
    if sys_oid != ".1.3.6.1.4.1.367.1.1":
        return {"changed": False, "msg": "Ricoh printer not detected", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.367.3.2.1.2.24.1.1.2"], mutates=False)
    if walk.rc != 0:
        return {"changed": False, "msg": "snmpwalk column 2 failed: rc=" + str(walk.rc), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    name_to_idx = {}
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1]
        idx = oid[len(".1.3.6.1.4.1.367.3.2.1.2.24.1.1.2") + 1:]
        raw_name = value.strip(' "')
        name_rev = raw_name.split(" ")
        if len(name_rev) == 2:
            name_rev = [name_rev[1], name_rev[0]]
        name = " ".join(name_rev)
        name_to_idx[name] = idx
    
    if item not in name_to_idx:
        return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    idx = name_to_idx[item]
    level_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.367.3.2.1.2.24.1.1.5." + idx], mutates=False)
    if level_res.rc != 0:
        return {"changed": False, "msg": "failed to get level for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    level_str = level_res.stdout.strip()
    if level_str.startswith("No") or level_str == "":
        return {"changed": False, "msg": "no level value for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    supply_level = 0
    if level_str.lstrip("-").isdigit():
        supply_level = int(level_str)
    else:
        return {"changed": False, "msg": "invalid level value for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    levels = params.get("levels", (20.0, 10.0))
    warn = levels[0]
    crit = levels[1]
    
    state = "OK"
    infotext = "%f%%" % supply_level
    
    if supply_level < 0:
        if supply_level == -100:
            state = "CRIT"
            infotext = "almost empty (<10%)"
            supply_level = 0
        elif supply_level == -2:
            state = "UNKNOWN"
            infotext = "unknown level"
            supply_level = 0
        elif supply_level == -3:
            state = "OK"
            infotext = "100%"
            supply_level = 100
        else:
            if supply_level <= crit:
                state = "CRIT"
            elif supply_level <= warn:
                state = "WARN"
            else:
                state = "OK"
            infotext = "%f%%" % supply_level
    else:
        if supply_level <= crit:
            state = "CRIT"
        elif supply_level <= warn:
            state = "WARN"
        else:
            state = "OK"
        if state != "OK":
            infotext += " (warn/crit at %f%%/%f%%)" % (warn, crit)
    
    lower_item = item.lower()
    if "black" in lower_item:
        perf_type = "black"
    elif "cyan" in lower_item:
        perf_type = "cyan"
    elif "magenta" in lower_item:
        perf_type = "magenta"
    elif "yellow" in lower_item:
        perf_type = "yellow"
    else:
        perf_type = "other"
    
    metric_name = "supply_toner_" + perf_type
    return {"changed": False, "msg": item + " " + infotext, "data": {"state": state, "metrics": {metric_name: supply_level}, "details": ""}}