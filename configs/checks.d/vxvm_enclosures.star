def main(ctx, params):
    # Discovery mode: enumerate all vxvm enclosures
    if params.get("_discover"):
        res = ctx.run(["vxdmpadm", "listenclosure"], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            parts = line.split()
            # Expected format: NAME DMPNAME ENCLNAME STATUS MODE ...
            if len(parts) >= 5:
                name = parts[0]
                status = parts[3]
                # Only include enclosures in a discoverable state
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d enclosures" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: verify one enclosure's status
    item = params.get("item", "")
    res = ctx.run(["vxdmpadm", "listenclosure"], mutates=False)
    found = False
    status = "UNKNOWN"
    
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] == item:
            status = parts[3]
            found = True
            break
    
    # Determine state based on status
    if not found:
        return {
            "changed": False,
            "msg": "enclosure '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state = "CRIT" if status != "CONNECTED" else "OK"
    msg = "Status is %s" % status
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""}
    }