def main(ctx, params):
    # Discovery mode: enumerate 3ware units
    if params.get("_discover"):
        res = ctx.run(["tw_cli", "show"], mutates=False)
        units = {}
        lines = res.stdout.splitlines() if res.stdout else []
        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue
            parts = stripped.split()
            if len(parts) < 4:
                continue
            unit_name = parts[0]
            if not (unit_name.startswith('u') and len(unit_name) > 1 and unit_name[1].isdigit()):
                continue
            unit_type = parts[1] if len(parts) > 1 else ""
            status = parts[2] if len(parts) > 2 else ""
            complete = parts[3] if len(parts) > 3 else "-"
            size = 0.0
            # Scan fields for size using guards only, no try/except
            for i in range(4, len(parts)):
                s = parts[i]
                if s == "":
                    continue
                # Guard against invalid numeric strings
                s_clean = s.lstrip('-')
                dot_count = s_clean.count('.')
                if dot_count > 1:
                    continue
                if not s_clean.replace('.', '').isdigit():
                    continue
                # Valid numeric string
                size = float(s)
            units[unit_name] = {
                "type": unit_type,
                "status": status,
                "complete": complete,
                "size": size
            }
        
        discovery = []
        for item, unit in sorted(units.items()):
            discovery.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d units" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode: examine one specific unit
    item = params.get("item", "")
    res = ctx.run(["tw_cli", "show"], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []
    units = {}
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split()
        if len(parts) < 4:
            continue
        unit_name = parts[0]
        if not (unit_name.startswith('u') and len(unit_name) > 1 and unit_name[1].isdigit()):
            continue
        unit_type = parts[1] if len(parts) > 1 else ""
        status = parts[2] if len(parts) > 2 else ""
        complete = parts[3] if len(parts) > 3 else "-"
        size = 0.0
        for i in range(4, len(parts)):
            s = parts[i]
            if s == "":
                continue
            s_clean = s.lstrip('-')
            dot_count = s_clean.count('.')
            if dot_count > 1:
                continue
            if not s_clean.replace('.', '').isdigit():
                continue
            size = float(s)
        units[unit_name] = {
            "type": unit_type,
            "status": status,
            "complete": complete,
            "size": size
        }
    
    if item not in units:
        return {
            "changed": False,
            "msg": "unit %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    unit = units[item]
    status = unit["status"]
    
    # Determine state based on status
    if status in ("OK", "VERIFYING"):
        state = "OK"
    elif status in ("INITIALIZING", "VERIFY-PAUSED", "REBUILDING"):
        state = "WARN"
    else:
        state = "CRIT"
    
    # Build summary message
    summary_parts = [status, "Type: " + unit["type"], "Size: " + str(unit["size"]) + "GB"]
    if unit["complete"] != "-":
        summary_parts.append("Complete: " + unit["complete"] + "%")
    summary = ", ".join(summary_parts)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""}
    }