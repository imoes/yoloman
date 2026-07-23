def _parse_omd_status(output):
    result = {}
    current_site = None
    current_data = None

    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current_site = line[1:-1]
            current_data = {"stopped": [], "existing": []}
            result[current_site] = current_data
            continue
        if current_data == None:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        state_val = parts[1]
        if name == "OVERALL":
            if state_val == "0":
                current_data["overall"] = "running"
            elif state_val == "1":
                current_data["overall"] = "stopped"
            current_site = None
            current_data = None
        else:
            current_data["existing"].append(name)
            if state_val != "0":
                current_data["stopped"].append(name)
                current_data["overall"] = "partially"

    return result


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["omd", "status", "--bare"], mutates=False, ok_codes=[0, 1, 2])
        sites = _parse_omd_status(res.stdout)
        discovery = []
        for site in sorted(sites.keys()):
            discovery.append({
                "item": site,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d OMD sites" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # omd status --bare <site> outputs daemon lines + OVERALL without a [site] header;
    # wrap it so _parse_omd_status can handle it uniformly.
    res = ctx.run(["omd", "status", "--bare", item], mutates=False, ok_codes=[0, 1, 2])
    wrapped = "[%s]\n%s" % (item, res.stdout)
    sites = _parse_omd_status(wrapped)

    if item not in sites:
        return {
            "changed": False,
            "msg": "site not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    site_data = sites[item]

    if "overall" not in site_data:
        state = "CRIT"
        msg = "defective installation"
    elif site_data["overall"] == "running":
        state = "OK"
        msg = "running"
    elif site_data["overall"] == "stopped":
        state = "CRIT"
        msg = "stopped"
    else:
        stopped = site_data.get("stopped", [])
        state = "CRIT"
        msg = "partially running, stopped services: " + ", ".join(stopped)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }