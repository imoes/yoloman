def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/checkmk-agent/cache/tsm_stagingpools"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "cannot read agent cache file",
                    "data": {"discovery": []}}
        
        # Parse the agent output
        parsed = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            inst, pool, util = parts[0], parts[1], parts[2]
            # Handle malformed lines with 6 parts (two lines merged)
            if len(parts) == 6:
                inst2, pool2, util2 = parts[3], parts[4], parts[5]
                add_item(parsed, inst2, pool2, util2)
            add_item(parsed, inst, pool, util)

        # Build discovery list
        discovery = []
        for item in parsed:
            discovery.append({"item": item, "params": {"free_below": 70, "levels": [5, 2]},
                              "metrics": ["free", "tapes", "util"]})
        return {"changed": False, "msg": "discovered %d staging pools" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    
    # Read agent cache for the current item
    res = ctx.run(["cat", "/var/lib/checkmk-agent/cache/tsm_stagingpools"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read agent cache file",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse agent output into a section-like dict
    section = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        inst, pool, util = parts[0], parts[1], parts[2]
        key = pool if inst == "default" else (inst + " / " + pool)
        section.setdefault(key, [])
        # Handle merged lines (6 parts)
        if len(parts) == 6:
            inst2, pool2, util2 = parts[3], parts[4], parts[5]
            key2 = pool2 if inst2 == "default" else (inst2 + " / " + pool2)
            section.setdefault(key2, []).append(util.replace(",", "."))
        section[key].append(util.replace(",", "."))

    # Check if item exists
    if item not in section:
        return {"changed": False, "msg": "pool not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Compute metrics
    num_tapes = 0
    num_free_tapes = 0
    utilization = 0.0
    free_below = params.get("free_below", 70)
    for util in section[item]:
        # Guard: only process if util is numeric
        util_clean = util.replace(",", ".")
        if util_clean.replace(".", "", 1).isdigit() or util_clean == ".":
            util_float = float(util_clean) / 100.0
            utilization += util_float
            num_tapes += 1
            if util_float <= free_below / 100.0:
                num_free_tapes += 1

    if num_tapes == 0:
        return {"changed": False, "msg": "No tapes in this pool or pool not existant.",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Determine state from levels
    levels = params.get("levels", [None, None])
    warn = levels[0] if levels[0] != None else None
    crit = levels[1] if levels[1] != None else None

    # Lower levels: warn if free <= warn, crit if free <= crit
    state = "OK"
    if crit != None and num_free_tapes <= crit:
        state = "CRIT"
    elif warn != None and num_free_tapes <= warn:
        state = "WARN"

    msg = "Total tapes: %d, Utilization: %f tapes, Tapes less than %d%% full: %d" % (
        num_tapes, utilization, free_below, num_free_tapes)
    if state != "OK":
        msg = "%s, %s" % (msg, state)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"free": num_free_tapes, "tapes": num_tapes, "util": utilization}, "details": ""}}


def add_item(parsed, inst, pool, util):
    key = pool if inst == "default" else (inst + " / " + pool)
    parsed.setdefault(key, [])
    parsed[key].append(util.replace(",", "."))
