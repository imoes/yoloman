def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["dmraid", "-r"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "dmraid command failed: " + res.stderr,
                    "data": {"discovery": []}}
        section = []
        for line in res.stdout.splitlines():
            if line.strip() == "":
                continue
            section.append(line.split())
        items = []
        for line in section:
            if len(line) > 0 and line[0].startswith("/dev/sd"):
                disk = line[0].split(":")[0]
                items.append({"item": disk, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d physical disks" % len(items),
                "data": {"discovery": items}}
    item = params.get("item", "")
    res = ctx.run(["dmraid", "-r"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "dmraid command failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = []
    for line in res.stdout.splitlines():
        if line.strip() == "":
            continue
        section.append(line.split())
    for line in section:
        if len(line) > 0 and line[0].startswith("/dev/sd"):
            disk = line[0].split(":")[0]
            if disk == item:
                if len(line) < 5:
                    return {"changed": False, "msg": "Incomplete data for disk " + item,
                            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
                status = line[4].split(",")[0]
                if status == "ok":
                    pos = -1
                    for i in range(len(line)):
                        if line[i] == "Model:":
                            pos = i
                            break
                    model = " ".join(line[pos + 1:]) if pos != -1 else "unknown"
                    return {"changed": False, "msg": "Online (%s)" % model,
                            "data": {"state": "OK", "metrics": {}, "details": ""}}
                return {"changed": False, "msg": "Error on disk!!",
                        "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Missing disk!!",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}}