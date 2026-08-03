def _parse_omd_status(text):
    result = {}
    current = None
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if len(parts) < 2:
            if parts[0].startswith("[") and parts[0].endswith("]"):
                name = parts[0]
                current = result.setdefault(name[1:-1], {"stopped": [], "existing": []})
            continue
        name = parts[0]
        if name.startswith("[") and name.endswith("]"):
            current = result.setdefault(name[1:-1], {"stopped": [], "existing": []})
            continue
        if current == None:
            continue
        state = parts[1]
        if name == "OVERALL":
            if state == "0":
                current["overall"] = "running"
            elif state == "1":
                current["overall"] = "stopped"
            current = None
            continue
        current["existing"].append(name)
        if state != "0":
            current["stopped"].append(name)
            current["overall"] = "partially"
    return result


def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["omd", "--version"], mutates=False)
        if probe.rc == 127 or probe.rc != 0:
            return {"changed": False, "msg": "omd not installed", "data": {"discovery": []}}
        res = ctx.run(["omd", "status"], mutates=False)
        if res.rc != 0 and not res.stdout:
            return {"changed": False, "msg": "omd status unavailable", "data": {"discovery": []}}
        section = _parse_omd_status(res.stdout)
        out = []
        for site in section.keys():
            out.append({"item": site, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    probe = ctx.run(["omd", "--version"], mutates=False)
    if probe.rc == 127 or probe.rc != 0:
        return {"changed": False, "msg": "omd not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run(["omd", "status"], mutates=False)
    if res.rc != 0 and not res.stdout:
        return {"changed": False, "msg": "omd status unavailable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_omd_status(res.stdout)
    if not section or item not in section:
        return {"changed": False, "msg": "site not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    svcs = section[item]
    overall = svcs.get("overall")
    if "overall" not in svcs:
        return {"changed": False, "msg": "defective installation", "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    if overall == "running":
        return {"changed": False, "msg": "running", "data": {"state": "OK", "metrics": {}, "details": ""}}
    if overall == "stopped":
        return {"changed": False, "msg": "stopped", "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    if overall == "partially":
        return {"changed": False, "msg": "partially running, stopped services: " + ", ".join(svcs.get("stopped", [])), "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "unknown overall state: " + str(overall), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}