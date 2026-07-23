def main(ctx, params):
    # Discovery mode: enumerate controllers from tw_cli show output
    if params.get("_discover"):
        res = ctx.run(["tw_cli", "show"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to run tw_cli show",
                    "data": {"discovery": []}}
        
        out = []
        lines = res.stdout.splitlines()
        # Skip header (first 2 lines: title and separator)
        for line in lines[2:]:
            parts = line.split()
            if len(parts) == 8 and parts[0].startswith("c"):
                item = parts[0]
                out.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d controllers" % len(out),
                "data": {"discovery": out}}
    
    # Check mode: single item
    item = params.get("item", "")
    res = ctx.run(["tw_cli", "show"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to run tw_cli show",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    found = False
    infotext = ""
    for line in lines[2:]:  # Skip header
        parts = line.split()
        if len(parts) >= 8 and parts[0] == item:
            found = True
            # Build Checkmk-style summary from columns 1..7
            parts_text = " ".join(parts[1:])
            infotext = parts_text + ";"
            break
    
    if not found:
        return {"changed": False, "msg": "controller not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    return {"changed": False, "msg": infotext,
            "data": {"state": "OK", "metrics": {}, "details": ""}}