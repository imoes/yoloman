# Module: sansymphony_virtualdiskstatus
# Checkmk check: sansymphony Virtual Disk %s
# Read-only Starlark translation — no mutations

def main(ctx, params):
    # --- discovery mode ---
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/diskstatus"], mutates=False)
        # Fallback if file doesn't exist: try alternative paths or agent output
        if res.rc != 0 or not res.stdout:
            # Agent output not available — no items discovered
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        parsed = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) >= 2:
                name = parts[0]
                status = parts[1]
                parsed[name] = status
        
        discovery = []
        for item in parsed:
            discovery.append({"item": item, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d virtual disks" % len(discovery),
                "data": {"discovery": discovery}}
    
    # --- check mode (one item) ---
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/diskstatus"], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parsed = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) >= 2:
            name = parts[0]
            status = parts[1]
            parsed[name] = status
    
    # Look up the item
    data = parsed.get(item)
    if data == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state = "OK" if data == "Online" else "CRIT"
    summary = "Volume state is: " + data
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
