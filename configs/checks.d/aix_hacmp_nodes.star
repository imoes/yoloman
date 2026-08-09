def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["clstat"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no HACMP found", "data": {"discovery": []}}
        out = []
        for line in res.stdout.splitlines():
            if line.startswith("node:") or "node" in line.lower() and ":" in line:
                node_name = line.split(":")[0].strip()
                if node_name:
                    out.append({"item": node_name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d nodes" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["clstat"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "HACMP not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    found = False
    for line in res.stdout.splitlines():
        if line.startswith("node:") or ("node" in line.lower() and ":" in line):
            node_name = line.split(":")[0].strip()
            if node_name == item:
                found = True
                break
    if not found:
        return {"changed": False, "msg": "node %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "HACMP node %s is active" % item,
            "data": {"state": "OK", "metrics": {}, "details": ""}}