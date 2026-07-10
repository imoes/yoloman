def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["tw_cli", "show"], mutates=False)
        units = []
        lines = res.stdout.splitlines()
        for line in lines:
            stripped = line.strip()
            if not stripped or stripped.startswith("Unit") or stripped.startswith("Controller"):
                continue
            parts = stripped.split()
            if len(parts) < 5:
                continue
            unit_name = parts[0]
            if unit_name.startswith("u") and unit_name[1:].isdigit():
                units.append({
                    "item": unit_name,
                    "params": {},
                    "metrics": []
                })
        return {"changed": False, "msg": "discovered %d units" % len(units),
                "data": {"discovery": units}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["tw_cli", "show"], mutates=False)
    section = {}
    lines = res.stdout.splitlines()
    
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("Unit") or stripped.startswith("Controller"):
            continue
        parts = stripped.split()
        if len(parts) < 5:
            continue
        unit_name = parts[0]
        if unit_name.startswith("u") and unit_name[1:].isdigit():
            unit_type = parts[1]
            status = parts[2]
            complete = parts[3]
            
            # Find size: look for first float after position 3
            size = 0.0
            found = False
            for i in range(4, len(parts)):
                candidate = parts[i]
                # Check if candidate looks like a number (integer or float)
                has_dot = candidate.find(".") != -1
                # Validate it contains only digits and at most one dot
                valid = True
                dot_count = 0
                for c in candidate:
                    if c == '.':
                        dot_count += 1
                        if dot_count > 1:
                            valid = False
                            break
                    elif not c.isdigit():
                        valid = False
                        break
                if valid and dot_count <= 1 and len(candidate) > 0:
                    size = float(candidate)
                    found = True
                    break
            if not found:
                size = 0.0
            
            section[unit_name] = {
                "type": unit_type,
                "status": status,
                "complete": complete,
                "size": size
            }
    
    unit = section.get(item)
    if unit == None:
        return {"changed": False, "msg": "unit %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status = unit["status"]
    if status in ["OK", "VERIFYING"]:
        state = "OK"
    elif status in ["INITIALIZING", "VERIFY-PAUSED", "REBUILDING"]:
        state = "WARN"
    else:
        state = "CRIT"
    
    summary_parts = [status]
    summary_parts.append("Type: %s" % unit["type"])
    summary_parts.append("Size: %.2fGB" % unit["size"])
    if unit["complete"] != "-":
        summary_parts.append("Complete: %s%%" % unit["complete"])
    
    msg = ", ".join(summary_parts)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}
