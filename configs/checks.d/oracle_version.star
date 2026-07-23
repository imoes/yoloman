def main(ctx, params):
    # Discover mode: enumerate Oracle database instances
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/oracle-version"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        
        out = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) >= 2:
                item = parts[0]
                out.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode: verify one specific Oracle instance
    item = params.get("item", "")
    
    # Read the oracle-version file
    res = ctx.run(["cat", "/var/lib/oracle-version"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no version information, database might be stopped",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Look for the requested item
    found = False
    summary = ""
    for line in res.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) >= 2 and parts[0] == item:
            summary = "Version: " + parts[1]
            found = True
            break
    
    if not found:
        return {
            "changed": False,
            "msg": "no version information, database might be stopped",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }