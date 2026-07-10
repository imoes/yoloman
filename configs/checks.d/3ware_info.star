def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["tw_cli", "show"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "tw_cli show failed", "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        discovered = []
        # Skip header lines; first line is header, second is separator, third onwards are data
        for line in lines[2:]:
            fields = line.split()
            if len(fields) == 8:
                item = fields[0]
                discovered.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })
        return {"changed": False, "msg": "discovered %d controllers" % len(discovered),
                "data": {"discovery": discovered}}
    
    item = params.get("item", "")
    res = ctx.run(["tw_cli", "show"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "tw_cli show failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    found = False
    infotext = ""
    for line in lines[2:]:  # skip headers
        fields = line.split()
        if len(fields) >= 1 and fields[0] == item:
            found = True
            line_text = " ".join(fields[1:]) + ";"
            infotext = infotext + line_text
    
    if not found:
        return {"changed": False, "msg": "controller %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Remove trailing semicolon if present
    if infotext.endswith(";"):
        infotext = infotext[:-1]
    
    return {"changed": False, "msg": infotext,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
