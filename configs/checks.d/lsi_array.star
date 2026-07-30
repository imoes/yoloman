MEGACLI_PATHS = [
    "/opt/MegaRAID/MegaCli/MegaCli64",
    "/usr/local/bin/MegaCli64",
    "/usr/bin/MegaCli64",
    "/opt/MegaRAID/MegaCli/MegaCli",
    "/usr/local/bin/MegaCli",
    "/usr/bin/MegaCli",
]

STATE_MAP = {
    "Optimal": "Okay(OKY)",
    "Degraded": "Degraded(DGD)",
    "Partially Degraded": "Partially Degraded(PDG)",
    "Failed": "Failed(FLD)",
    "Offline": "Offline(OFL)",
}

def _find_megacli(ctx):
    for path in MEGACLI_PATHS:
        if ctx.file_exists(path):
            return path
    return None

def _parse_arrays(stdout):
    arrays = {}
    current_vd = None
    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Virtual Drive:") and "(" in stripped:
            parts = stripped.split()
            if len(parts) >= 3:
                current_vd = parts[2]
        elif stripped.startswith("State") and ":" in stripped and current_vd != None:
            state_raw = stripped.split(":", 1)[1].strip()
            arrays[current_vd] = STATE_MAP.get(state_raw, state_raw)
    return arrays

def main(ctx, params):
    megacli = _find_megacli(ctx)

    if params.get("_discover"):
        if megacli == None:
            return {"changed": False, "msg": "discovered 0 arrays",
                    "data": {"discovery": []}}
        res = ctx.run([megacli, "-LDInfo", "-Lall", "-aAll", "-NoLog"],
                      mutates=False, ok_codes=list(range(10)))
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 arrays",
                    "data": {"discovery": []}}
        arrays = _parse_arrays(res.stdout)
        discovery = [
            {"item": vol_id, "params": {}, "metrics": []}
            for vol_id, _ in arrays.items()
        ]
        return {"changed": False, "msg": "discovered %d arrays" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    if megacli == None:
        return {"changed": False, "msg": "MegaCli binary not found",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "MegaCli not installed"}}

    res = ctx.run([megacli, "-LDInfo", "-Lall", "-aAll", "-NoLog"],
                  mutates=False, ok_codes=list(range(10)))
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "MegaCli returned rc=%d" % res.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr}}

    arrays = _parse_arrays(res.stdout)

    if item not in arrays:
        return {"changed": False, "msg": "RAID volume %s not existing" % item,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    state_str = arrays[item]
    check_state = "OK" if state_str == "Okay(OKY)" else "CRIT"
    return {"changed": False, "msg": "Status is '%s'" % state_str,
            "data": {"state": check_state, "metrics": {}, "details": ""}}