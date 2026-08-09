def _parse_rows(stdout):
    rows = []
    for line in stdout.split("\n"):
        parts = line.strip().split()
        if len(parts) >= 2:
            rows.append(parts)
    return rows

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["hdbnsutil", "-verify"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "hdbnsutil not available", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": [], "host_labels": {}}}
    item = params.get("item", "")
    res = ctx.run(["hdbnsutil", "-verify"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SAP HANA not detected on this host", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "", "data": {"state": "OK", "metrics": {}, "details": ""}}