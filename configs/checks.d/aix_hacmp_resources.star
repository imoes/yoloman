def _parse_resources(output):
    parsed = {}
    for line in output.splitlines():
        if "There is no cluster definition" in line or "Status of the RSCT subsystems" in line:
            continue
        parts = line.split(":")
        if len(parts) < 3:
            continue
        rg = parts[0]
        state = parts[1].lower()
        node = parts[2]
        parsed.setdefault(rg, []).append((node, state))
    return parsed

def _gather_hacmp_raw(ctx, params):
    res = ctx.run(["lssrc", "-a", "-g", "cluster"], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    raw = res.stdout
    if "There is no cluster definition" in raw or "inoperative" in raw.lower() or "not running" in raw.lower():
        res2 = ctx.run(["cl_showcluster"], mutates=False)
        if res2.rc == 0:
            return res2.stdout
        return None
    if "There is no cluster definition" in raw:
        return None
    return raw

def main(ctx, params):
    if params.get("_discover"):
        raw = _gather_hacmp_raw(ctx, params)
        if raw == None:
            return {"changed": False, "msg": "no HACMP found",
                    "data": {"discovery": []}}
        parsed = _parse_resources(raw)
        discovery = []
        for rg in parsed:
            discovery.append({"item": rg, "params": {"expect_online_on": "first"},
                              "metrics": []})
        return {"changed": False,
                "msg": "discovered %d HACMP resource groups" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    raw = _gather_hacmp_raw(ctx, params)
    if raw == None:
        return {"changed": False, "msg": "no HACMP cluster source found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = _parse_resources(raw)
    data = parsed.get(item)
    if not data:
        return {"changed": False, "msg": "resource group %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    expected_behaviour = params.get("expect_online_on", "first")
    resource_states = []
    infotext = []
    for pair in data:
        node_name = pair[0]
        resource_state = pair[1]
        resource_states.append(resource_state)
        infotext.append("%s on node %s" % (resource_state, node_name))

    state = "OK"
    if expected_behaviour == "first":
        if resource_states[0] != "online":
            state = "CRIT"
    elif expected_behaviour == "any":
        found_online = False
        for resource_state in resource_states:
            if resource_state == "online":
                found_online = True
                break
        if not found_online:
            state = "CRIT"

    return {"changed": False, "msg": ", ".join(infotext),
            "data": {"state": state, "metrics": {}, "details": ""}}