def _map_status(raw):
    s = raw.lower()
    if s == "up" or s == "ok":
        return "ok"
    if s == "down" or s == "degraded" or s == "halted":
        return "degraded"
    return s

def _parse_cmviewcl(stdout):
    lines = stdout.splitlines()
    items = []
    section = ""

    for line in lines:
        if not line.strip():
            continue
        stripped = line.strip()
        upper = stripped.upper()

        if not line.startswith(" ") and not line.startswith("\t"):
            if upper.startswith("CLUSTER") and "STATUS" in upper:
                section = "cluster"
                continue
            if upper.startswith("NODE") and "STATUS" in upper:
                section = "node"
                continue
            if upper.startswith("PACKAGE") and "STATUS" in upper:
                section = "package"
                continue

        if line.startswith(" ") or line.startswith("\t"):
            continue

        parts = stripped.split()
        if len(parts) < 2:
            continue

        status = _map_status(parts[1])

        if section == "cluster":
            items.append({"label": "", "status": status})
            section = ""
        elif section == "node":
            items.append({"label": "node:" + parts[0], "status": status})
        elif section == "package":
            items.append({"label": "package:" + parts[0], "status": status})

    return items

def main(ctx, params):
    res = ctx.run(["cmviewcl"], mutates=False, ok_codes=[0, 1])

    if res.rc != 0 or not res.stdout.strip():
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "cmviewcl returned no data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    items = _parse_cmviewcl(res.stdout)

    if params.get("_discover"):
        discovery = []
        for it in items:
            label = it["label"]
            disc_item = "Total Status" if label == "" else label
            discovery.append({"item": disc_item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    for it in items:
        label = it["label"]
        if (item == "Total Status" and label == "") or (item == label):
            status = it["status"]
            if status == "ok":
                state = "OK"
            elif status == "degraded":
                state = "WARN"
            else:
                state = "CRIT"
            return {
                "changed": False,
                "msg": "state is " + status,
                "data": {"state": state, "metrics": {}, "details": ""},
            }

    return {
        "changed": False,
        "msg": "No such item found",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }