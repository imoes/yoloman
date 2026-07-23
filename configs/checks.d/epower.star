# Module-level constants (Checkmk defaults)
DEFAULT_LEVELS_LOWER = (20, 1)
DEFAULT_LEVELS_UPPER = None

def main(ctx, params):
    if params.get("_discover"):
        # Read power data from agent (assume format: "phase_name power_W" per line)
        res = ctx.run(["cat", "/proc/epower"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 phases",
                    "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[1].isdigit():
                phase = parts[0]
                items.append({
                    "item": phase,
                    "params": {
                        "levels_lower": DEFAULT_LEVELS_LOWER,
                        "levels_upper": DEFAULT_LEVELS_UPPER
                    },
                    "metrics": ["power"]
                })
        
        return {"changed": False, "msg": "discovered %d phases" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/epower"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read epower data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    power = None
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0] == item:
            if parts[1].isdigit():
                power = int(parts[1])
            break
    
    if power == None:
        return {"changed": False, "msg": "no data for phase %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    levels_lower = params.get("levels_lower", DEFAULT_LEVELS_LOWER)
    levels_upper = params.get("levels_upper", DEFAULT_LEVELS_UPPER)
    
    # Determine state based on levels
    state = "OK"
    reason = []
    
    # Upper levels check
    if levels_upper != None:
        warn_upper, crit_upper = levels_upper
        if power >= crit_upper:
            state = "CRIT"
            reason.append("CRIT >= %d W" % crit_upper)
        elif power >= warn_upper:
            state = "WARN"
            reason.append("WARN >= %d W" % warn_upper)
    
    # Lower levels check
    if levels_lower != None:
        warn_lower, crit_lower = levels_lower
        if power <= crit_lower:
            state = "CRIT"
            reason.append("CRIT <= %d W" % crit_lower)
        elif power <= warn_lower:
            state = "WARN"
            reason.append("WARN <= %d W" % warn_lower)
    
    msg = "Power: %d W" % power
    if reason:
        msg += " - " + ", ".join(reason)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"power": power}, "details": ""}}
