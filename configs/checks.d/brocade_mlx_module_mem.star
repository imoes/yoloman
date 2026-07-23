def _saveint(i):
    if i.isdigit():
        return int(i)
    else:
        return 0

def _get_state(state):
    states = {
        0: ("WARN", "Slot is empty"),
        2: ("WARN", "Module is going down"),
        3: ("CRIT", "Rejected due to wrong configuration"),
        4: ("CRIT", "Hardware is bad"),
        8: ("WARN", "Configured / Stacking"),
        9: ("WARN", "In power-up cycle"),
        10: ("OK", "Running"),
        11: ("OK", "Blocked for full height card"),
    }
    if state in states:
        return states[state]
    else:
        return ("UNKNOWN", "Unhandled state - %s" % state)

def _combine_item(id_, descr):
    if descr == "":
        return id_
    descr = descr.replace(" Module", "").replace("  Module", " Module").strip()
    return "%s %s" % (id_, descr) if descr != "" else id_

def _parse_section(section):
    parsed = {}
    for row in section:
        if len(row) < 5:
            continue
        module_id = row[0]
        module_descr = row[1]
        module_state = row[2]
        mem_total = row[3]
        mem_avail = row[4]
        
        item = _combine_item(module_id, module_descr)
        state_val = _saveint(module_state)
        state_readable = _get_state(state_val)[1]
        
        if not (item in parsed):
            parsed[item] = {"state_readable": state_readable, "descr": module_descr}
        
        if mem_total.isdigit():
            parsed[item]["mem_total"] = int(mem_total)
        
        if mem_avail.isdigit():
            parsed[item]["mem_avail"] = int(mem_avail)
    
    return parsed

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.1991.1.1.2.2.1.1"
        ], mutates=False)
        
        oid_map = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            oid = parts[0]
            if not oid.startswith(".1.3.6.1.4.1.1991.1.1.2.2.1.1."):
                continue
            rest = oid[len(".1.3.6.1.4.1.1991.1.1.2.2.1.1."):]
            dot_pos = rest.find(".")
            if dot_pos == -1:
                continue
            idx_str = rest[:dot_pos]
            field_oid_str = rest[dot_pos+1:]
            if not (idx_str.isdigit() and field_oid_str.isdigit()):
                continue
            idx = int(idx_str)
            field_oid = int(field_oid_str)
            
            field_idx_map = {1: 0, 2: 1, 12: 2, 24: 3, 25: 4}
            if field_oid not in field_idx_map:
                continue
            field_idx = field_idx_map[field_oid]
            
            value = parts[3].rstrip(":").strip()
            if not (idx in oid_map):
                oid_map[idx] = [None, None, None, None, None]
            oid_map[idx][field_idx] = value
        
        section = []
        for idx in sorted(oid_map.keys()):
            row = oid_map[idx]
            if len(row) < 5:
                continue
            module_id = row[0] if row[0] != None else "0"
            module_descr = row[1] if row[1] != None else ""
            module_state = row[2] if row[2] != None else "0"
            mem_total = row[3] if row[3] != None else "0"
            mem_avail = row[4] if row[4] != None else "0"
            section.append([module_id, module_descr, module_state, mem_total, mem_avail])
        
        out = []
        parsed = _parse_section(section)
        for item, data in parsed.items():
            state_readable = data.get("state_readable", "")
            descr = data.get("descr", "")
            if state_readable == "Slot is empty" or state_readable == "Blocked for full height card":
                continue
            if not descr.startswith("NI-MLX") and not descr.startswith("BR-MLX"):
                continue
            out.append({
                "item": item,
                "params": {"levels": [80.0, 90.0]},
                "metrics": ["mem_used"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d memory modules" % len(out),
            "data": {"discovery": out}
        }
    
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.1991.1.1.2.2.1.1"
    ], mutates=False)
    
    oid_map = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 4:
            continue
        oid = parts[0]
        if not oid.startswith(".1.3.6.1.4.1.1991.1.1.2.2.1.1."):
            continue
        rest = oid[len(".1.3.6.1.4.1.1991.1.1.2.2.1.1."):]
        dot_pos = rest.find(".")
        if dot_pos == -1:
            continue
        idx_str = rest[:dot_pos]
        field_oid_str = rest[dot_pos+1:]
        if not (idx_str.isdigit() and field_oid_str.isdigit()):
            continue
        idx = int(idx_str)
        field_oid = int(field_oid_str)
        
        field_idx_map = {1: 0, 2: 1, 12: 2, 24: 3, 25: 4}
        if field_oid not in field_idx_map:
            continue
        field_idx = field_idx_map[field_oid]
        
        value = parts[3].rstrip(":").strip()
        if not (idx in oid_map):
            oid_map[idx] = [None, None, None, None, None]
        oid_map[idx][field_idx] = value
    
    section = []
    for idx in sorted(oid_map.keys()):
        row = oid_map[idx]
        if len(row) < 5:
            continue
        module_id = row[0] if row[0] != None else "0"
        module_descr = row[1] if row[1] != None else ""
        module_state = row[2] if row[2] != None else "0"
        mem_total = row[3] if row[3] != None else "0"
        mem_avail = row[4] if row[4] != None else "0"
        section.append([module_id, module_descr, module_state, mem_total, mem_avail])
    
    parsed = _parse_section(section)
    data = parsed.get(item)
    
    if data == None:
        return {
            "changed": False,
            "msg": "Module not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state_readable = data.get("state_readable", "")
    if not (state_readable.lower() == "running"):
        return {
            "changed": False,
            "msg": "Module is not running (Current State: %s)" % state_readable,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    mem_total = data.get("mem_total")
    mem_avail = data.get("mem_avail")
    
    if mem_total == None or mem_avail == None:
        return {
            "changed": False,
            "msg": "Missing memory data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    used = mem_total - mem_avail
    levels = params.get("levels")
    if levels != None:
        warn = levels[0] if len(levels) >= 1 else 80.0
        crit = levels[1] if len(levels) >= 2 else 90.0
    else:
        warn = 80.0
        crit = 90.0
    
    used_percent = 0.0
    if mem_total > 0:
        used_percent = (used * 100.0) / mem_total
    
    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    
    return {
        "changed": False,
        "msg": "Usage: %f%%, Total: %d MB, Available: %d MB" % (
            used_percent, mem_total / 1024, mem_avail / 1024),
        "data": {
            "state": state,
            "metrics": {"mem_used": used, "mem_used_percent": used_percent},
            "details": ""
        }
    }