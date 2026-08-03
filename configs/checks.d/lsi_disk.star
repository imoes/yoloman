def main(ctx, params):
    if params.get("_discover"):
        storcli = ctx.run(["storcli", "show"], mutates=False)
        if storcli.rc == 127:
            return {"changed": False, "msg": "storcli not installed", "data": {"discovery": []}}
        res = ctx.run(["storcli", "show", "all"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "storcli show failed", "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        disks = _parse_storcli_disks(lines)
        out = []
        for item, state in disks.items():
            out.append({"item": item, "params": {"expected_state": state},
                        "metrics": []})
        return {"changed": False, "msg": "discovered %d RAID disks" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["storcli", "show", "all"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "storcli not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "storcli show failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    disks = _parse_storcli_disks(res.stdout.splitlines())
    state = disks.get(item)
    if state == None:
        return {"changed": False, "msg": "Disk not present",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    expected = params.get("expected_state")
    if expected == None:
        expected = state
    if state == expected:
        return {"changed": False, "msg": "Disk has state '%s'" % state,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False,
            "msg": "Disk has state '%s' (should be '%s')" % (state, expected),
            "data": {"state": "CRIT", "metrics": {}, "details": ""}}


def _parse_storcli_disks(lines):
    disks = {}
    for line in lines:
        parts = line.split()
        if len(parts) >= 5:
            if parts[0] == "PD:":
                if len(parts) >= 4:
                    dev_id = parts[1]
                    state_raw = parts[3]
                    sval = _extract_state(state_raw)
                    if sval != None:
                        disks[dev_id] = sval
    return disks


def _extract_state(state_str):
    paren_idx = state_str.rfind("(")
    if paren_idx > 0 and state_str.endswith(")"):
        inner = state_str[paren_idx + 1:-1]
        if len(inner) >= 2 and inner[-1] == "L":
            return inner[:-1] if len(inner) > 2 else inner
    return None