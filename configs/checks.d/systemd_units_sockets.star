def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["systemctl", "list-unit-files", "--type=socket", "--no-legend", "--no-pager"], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) >= 1:
                unit = parts[0]
                if unit.endswith(".socket"):
                    name = unit[:-7]  # strip ".socket"
                    # Skip checkmk-agent sockets
                    if not name.startswith("check-mk-agent@"):
                        out.append({"item": name, "params": {
                            "states": {"active": 0, "inactive": 0, "failed": 2},
                            "states_default": 2,
                            "else": 2,
                        }, "metrics": []})
        return {"changed": False, "msg": "discovered %d sockets" % len(out), "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["systemctl", "show", "--type=socket", "--property=Id,ActiveState,LoadState,SubState,Description,UnitFileState,StateChangeTimestampMonotonic,MemoryCurrent,CPUUsageNSec,TasksCurrent", item + ".socket"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "socket not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    block = {}
    for line in res.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            block[key] = value.strip()
    
    if not block:
        return {"changed": False, "msg": "socket not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    active_status = block.get("ActiveState", "")
    load_status = block.get("LoadState", "")
    sub_state = block.get("SubState", "")
    description = block.get("Description", "")
    enabled_status = block.get("UnitFileState")
    
    # Map to Checkmk state logic
    states_map = params.get("states", {"active": 0, "inactive": 0, "failed": 2})
    default_state = params.get("states_default", 2)
    else_state = params.get("else", 2)
    
    if active_status == "":
        state = else_state
        summary = "Unit not found"
    else:
        state = states_map.get(active_status, default_state)
        summary = "Status: " + active_status
    
    state_text = ["OK", "WARN", "CRIT", "UNKNOWN"][state] if state <= 3 else "UNKNOWN"
    
    return {"changed": False, "msg": summary, "data": {"state": state_text, "metrics": {}, "details": description}}