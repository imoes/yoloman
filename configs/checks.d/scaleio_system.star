def main(ctx, params):
    if not params.get("host"):
        host = "localhost"
    else:
        host = params.get("host", "localhost")
    
    if not params.get("community"):
        community = ""
    else:
        community = params.get("community")

    def probe_scli():
        res = ctx.run(["scli", "--version"], mutates=False)
        if res.rc == 127:
            return None
        if res.rc != 0:
            return None
        return True

    scaleio_present = probe_scli()

    if params.get("_discover"):
        if not scaleio_present:
            return {"changed": False, "msg": "no ScaleIO found", "data": {"discovery": []}}
        
        res = ctx.run(["scli", "--query"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "scli query failed", "data": {"discovery": []}}
        
        sections = _parse_scli_query(res.stdout)
        systems = sections.get("SYSTEM", {})
        
        out = []
        for sys_id in sorted(systems.keys()):
            data = systems[sys_id]
            warn_default, crit_default = _derive_thresholds(data)
            out.append({
                "item": sys_id,
                "params": {"levels": (warn_default, crit_default)},
                "metrics": ["used_percent"],
            })
        return {"changed": False, "msg": "discovered %d systems" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    if not scaleio_present:
        return {"changed": False, "msg": "no ScaleIO found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "scli not installed"}}
    
    res = ctx.run(["scli", "--query"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "scli query failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": "scli query returned rc=%d" % res.rc}}
    
    sections = _parse_scli_query(res.stdout)
    systems = sections.get("SYSTEM", {})
    
    if item not in systems:
        return {"changed": False, "msg": "no such ScaleIO system: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = systems[item]
    warn_default, crit_default = _derive_thresholds(data)
    levels = params.get("levels", (warn_default, crit_default))
    warn = levels[0] if len(levels) > 0 else warn_default
    crit = levels[1] if len(levels) > 1 else crit_default
    
    total_kb = int(data.get("MAX_CAPACITY_IN_KB", ["0", "0", "0"])[2].strip("(")) if "MAX_CAPACITY_IN_KB" in data else 0
    free_kb = int(data.get("UNUSED_CAPACITY_IN_KB", ["0", "0", "0"])[2].strip("(")) if "UNUSED_CAPACITY_IN_KB" in data else 0
    
    total = float(total_kb * 1024)
    free = float(free_kb * 1024)
    
    if total <= 0:
        return {"changed": False, "msg": "ScaleIO System %s: total capacity is zero" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    used = total - free
    used_percent = (used / total) * 100.0
    
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "ScaleIO System %s: %s%% used (%f GB of %f GB)" % (item, "%f" % used_percent, used / (1024*1024*1024), total / (1024*1024*1024)),
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent, "total_bytes": total, "free_bytes": free, "used_bytes": used},
            "details": "MAX_CAPACITY: %f GB, UNUSED: %f GB, USED: %f GB" % (total/(1024*1024*1024), free/(1024*1024*1024), used/(1024*1024*1024)),
        },
    }


def _parse_scli_query(output):
    sections = {}
    current_section = ""
    current_item_id = ""
    
    for line in output.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        
        if stripped.endswith(":") and " " not in stripped.rstrip(":"):
            idx = stripped.rstrip(":")
            current_section = idx
            if current_section not in sections:
                sections[current_section] = {}
            current_item_id = ""
            continue
        
        if current_section == "SYSTEM" or current_section.startswith("SYSTEM"):
            if stripped.startswith("ID"):
                parts = stripped.split(None, 1)
                if len(parts) >= 2:
                    current_item_id = parts[1].strip()
                    sections.setdefault("SYSTEM", {}).setdefault(current_item_id, {})
            elif current_item_id:
                parts = stripped.split(None, 1)
                key = parts[0].strip() if len(parts) >= 1 else ""
                values = parts[1].strip() if len(parts) >= 2 else ""
                sections["SYSTEM"][current_item_id][key] = values.split() if values else []
        else:
            if stripped.startswith("ID") or "=" in stripped:
                parts = stripped.split("=", 1)
                if len(parts) == 2:
                    key = parts[0].strip()
                    val = parts[1].strip()
                    sections.setdefault(current_section, {}).setdefault(key, val.split())
    
    return sections


def _derive_thresholds(data):
    warn = 80.0
    crit = 90.0
    
    high = data.get("CAPACITY_ALERT_HIGH_THRESHOLD", [])
    if high and len(high) > 0:
        try_val = high[0].strip("%")
        if _is_number(try_val):
            warn = float(try_val)
    
    high_crit = data.get("CAPACITY_ALERT_CRITICAL_THRESHOLD", [])
    if high_crit and len(high_crit) > 0:
        try_val = high_crit[0].strip("%")
        if _is_number(try_val):
            crit = float(try_val)
    
    return warn, crit


def _is_number(s):
    if not s:
        return False
    for ch in s:
        if ch not in "0123456789.-":
            return False
    return True