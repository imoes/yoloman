def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/drbd"], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            if stripped[0] == " " and stripped[1].isdigit() and stripped.rstrip().endswith(":"):
                item = "drbd" + stripped.split(":")[0].strip()
                out.append({"item": item, "params": {}, "metrics": ["in", "out"]})
        return {"changed": False, "msg": "discovered %d DRBD network devices" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/drbd"], mutates=False)
    lines = res.stdout.splitlines()
    block = []
    in_block = False
    
    for line in lines:
        stripped = line.strip()
        if not stripped or not stripped[0].isspace():
            continue
        if stripped[0] == " " and stripped[1].isdigit() and stripped.rstrip().endswith(":"):
            resource = stripped.split(":")[0].strip()
            if "drbd" + resource == item:
                in_block = True
                block.append(stripped)
            else:
                if in_block:
                    break
        elif in_block:
            block.append(stripped)
    
    if not block:
        return {"changed": False, "msg": "device %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parsed = {}
    for line in block:
        if ":" in line:
            parts = line.split(":", 1)
            if len(parts) == 2:
                key = parts[0].strip()
                if key in ["ns", "nr"]:
                    parsed[key] = parts[1].strip()
    
    cs = None
    for line in block:
        if "cs:" in line:
            cs_part = line.split("cs:")[1].strip().split()[0]
            cs = cs_part
            break
    
    if cs == "Unconfigured":
        return {"changed": False, "msg": 'The device is "Unconfigured"',
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    nr_str = parsed.get("nr", "")
    ns_str = parsed.get("ns", "")
    
    nr = int(nr_str) if nr_str.isdigit() else 0
    ns = int(ns_str) if ns_str.isdigit() else 0
    
    metrics = {"in": nr, "out": ns}
    return {"changed": False,
            "msg": "Network in: %d KiB, out: %d KiB" % (nr, ns),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}