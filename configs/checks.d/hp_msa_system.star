# Helper to parse hp_msa_system agent output
def _parse_hp_msa_system(output):
    parsed = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        if parts[2] == "system-name":
            system_name = " ".join(parts[3:])
            parsed[system_name] = {"item_type": parts[0]}
        elif parts[2] == "health-numeric":
            # Use the last system_name we found
            if len(parts) > 3 and system_name:
                parsed[system_name]["health-numeric"] = parts[3]
        elif parts[2] == "health-reason":
            # health-reason may span multiple words
            reason = " ".join(parts[3:]) if len(parts) > 3 else ""
            if system_name:
                parsed[system_name]["health-reason"] = reason
    return parsed

# Map numeric health to state string
_HEALTH_MAP = {
    "0": "OK",
    "1": "Degraded",
    "2": "Critical",
}

def main(ctx, params):
    # Discovery mode: enumerate all discovered systems
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/diskinfo/hp_msa_system"], mutates=False)
        parsed = _parse_hp_msa_system(res.stdout) if res.stdout else {}
        items = []
        for system_name, data in parsed.items():
            item = system_name
            health_numeric = data.get("health-numeric", "999")
            health_reason = data.get("health-reason", "")
            items.append({
                "item": item,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d systems" % len(items),
            "data": {"discovery": items},
        }

    # Check mode: one item (system name)
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/diskinfo/hp_msa_system"], mutates=False)
    parsed = _parse_hp_msa_system(res.stdout) if res.stdout else {}
    
    # Check if item exists
    if item not in parsed:
        return {
            "changed": False,
            "msg": "system not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    data = parsed[item]
    health_numeric = data.get("health-numeric", "999")
    health_reason = data.get("health-reason", "")
    
    # Determine state based on numeric health
    state_str = _HEALTH_MAP.get(health_numeric, "UNKNOWN")
    if state_str == "UNKNOWN":
        msg = "unknown health (numeric=%s)" % health_numeric
    else:
        msg = state_str
        if health_reason:
            msg += ": " + health_reason
    
    # Map state strings to Checkmk states
    if state_str == "OK":
        state = "OK"
    elif state_str == "Critical":
        state = "CRIT"
    elif state_str == "Degraded":
        state = "WARN"
    else:
        state = "UNKNOWN"
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }