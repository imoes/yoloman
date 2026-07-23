# Constants for status mapping
STATUS_ACTIVE = "active"
STATUS_ONLINE = "online"
STATUS_DEGRADED = "degraded"
STATUS_OFFLINE = "offline"
STATUS_INACTIVE = "inactive"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/driver/ibm_svc_host"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 hosts",
                    "data": {"discovery": []}}
        
        found = False
        for line in res.stdout.splitlines():
            if line.strip() == "" or line.startswith("<<<") or line.startswith(">>>"):
                continue
            parts = line.split(":")
            if len(parts) >= 5 and parts[0].isdigit():
                found = True
                break
        
        if found:
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        else:
            return {"changed": False, "msg": "discovered 0 hosts",
                    "data": {"discovery": []}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/driver/ibm_svc_host"], mutates=False)
    
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "No data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    degraded = 0
    offline = 0
    active = 0
    inactive = 0
    other = 0
    
    for line in res.stdout.splitlines():
        if line.strip() == "":
            continue
        parts = line.split(":")
        if len(parts) >= 5:
            status = parts[4].strip()
            if status == STATUS_DEGRADED:
                degraded += 1
            elif status == STATUS_OFFLINE:
                offline += 1
            elif status == STATUS_ACTIVE or status == STATUS_ONLINE:
                active += 1
            elif status == STATUS_INACTIVE:
                inactive += 1
            else:
                other += 1
    
    # Default thresholds - none specified, use defaults
    active_levels = params.get("active_hosts")
    inactive_levels = params.get("inactive_hosts")
    degraded_levels = params.get("degraded_hosts")
    offline_levels = params.get("offline_hosts")
    other_levels = params.get("other_hosts")
    
    state = "OK"
    summary_parts = []
    
    # Active hosts - lower levels (more is better)
    if active_levels:
        warn, crit = active_levels
        if active <= crit:
            state = "CRIT"
        elif active <= warn:
            state = "WARN" if state != "CRIT" else state
        summary_parts.append("%d active" % active)
    else:
        summary_parts.append("%d active" % active)
    
    # Inactive, degraded, offline, other - upper levels (less is better)
    for name, value, levels in [
        ("inactive", inactive, inactive_levels),
        ("degraded", degraded, degraded_levels),
        ("offline", offline, offline_levels),
        ("other", other, other_levels),
    ]:
        if levels:
            warn, crit = levels
            if value >= crit:
                state = "CRIT"
            elif value >= warn:
                state = "WARN" if state != "CRIT" else state
        summary_parts.append("%d %s" % (value, name))
    
    metrics = {
        "active": active,
        "inactive": inactive,
        "degraded": degraded,
        "offline": offline,
        "other": other
    }
    
    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }