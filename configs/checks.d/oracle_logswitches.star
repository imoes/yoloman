# Constants for default levels (from Checkmk check defaults)
DEFAULT_LEVELS = (50, 100)       # (warn, crit) upper levels
DEFAULT_LEVELS_LOWER = (-1, -1)  # (warn, crit) lower levels

def main(ctx, params):
    # Discovery mode: enumerate all databases with logswitch data
    if params.get("_discover"):
        section_file = "/var/lib/check-mk-agent/oracle_logswitches"
        if not ctx.file_exists(section_file):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        content = ctx.file_read(section_file)
        lines = content.split("\n")
        out = []
        for line in lines:
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) == 2:
                item = parts[0]
                out.append({
                    "item": item,
                    "params": {"levels": DEFAULT_LEVELS, "levels_lower": DEFAULT_LEVELS_LOWER},
                    "metrics": ["logswitches"]
                })
        return {"changed": False, "msg": "discovered %d databases" % len(out),
                "data": {"discovery": out}}

    # Check mode: verify one item
    item = params.get("item", "")
    section_file = "/var/lib/check-mk-agent/oracle_logswitches"
    if not ctx.file_exists(section_file):
        return {"changed": False,
                "msg": "agent data not found: %s" % section_file,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    content = ctx.file_read(section_file)
    lines = content.split("\n")
    for line in lines:
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) != 2:
            continue
        db_name = parts[0]
        if db_name == item:
            # Guard: verify the second part is numeric before conversion
            switch_str = parts[1]
            if not switch_str.isdigit():
                return {"changed": False,
                        "msg": "invalid logswitches value for %s" % item,
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            logswitches = int(switch_str)
            
            # Extract levels from params
            levels = params.get("levels", DEFAULT_LEVELS)
            levels_lower = params.get("levels_lower", DEFAULT_LEVELS_LOWER)
            
            warn_upper, crit_upper = levels
            warn_lower, crit_lower = levels_lower
            
            # Determine state
            state = "OK"
            msg_parts = []
            msg_parts.append("Log switches: %d" % logswitches)
            
            # Upper levels (warn/crit if value >= warn/crit)
            if crit_upper != None and logswitches >= crit_upper:
                state = "CRIT"
                msg_parts.append("CRIT (warn: %d, crit: %d)" % (warn_upper, crit_upper))
            elif warn_upper != None and logswitches >= warn_upper:
                state = "WARN"
                msg_parts.append("WARN (warn: %d, crit: %d)" % (warn_upper, crit_upper))
            
            # Lower levels (warn/crit if value <= warn/crit)
            if crit_lower != None and logswitches <= crit_lower:
                state = "CRIT"
                msg_parts.append("CRIT lower (warn: %d, crit: %d)" % (warn_lower, crit_lower))
            elif warn_lower != None and logswitches <= warn_lower:
                state = "WARN"
                msg_parts.append("WARN lower (warn: %d, crit: %d)" % (warn_lower, crit_lower))
            
            # Metrics: only logswitches (as number)
            metrics = {"logswitches": logswitches}
            return {"changed": False,
                    "msg": ", ".join(msg_parts),
                    "data": {"state": state, "metrics": metrics, "details": ""}}
    
    # If we didn't find the item, it's not present in the section
    return {"changed": False,
            "msg": "database %s not found in agent data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
