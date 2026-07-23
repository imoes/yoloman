def main(ctx, params):
    # Run the command to get scratch pool count
    # We use the same command structure as the Checkmk agent plugin would use
    # Based on the parse function, we expect 3 fields per line: inst, tapes, library
    res = ctx.run(["dsmadmc", "-dataonly=yes", "-noheadings", "-seperator", "|",
                   "SELECT", "'default'", ",", "COUNT(*)", ",", "'default'", "FROM", "STAGEPOOLS", "WHERE", "POOLNAME='SCRATCH'"],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "TSM command failed or dsmadmc not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    out = res.stdout.strip()
    if not out:
        return {"changed": False, "msg": "No data from TSM",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the output: we expect lines of the form: default|<count>|default
    lines = out.splitlines()
    section = {}
    for line in lines:
        parts = line.split("|")
        if len(parts) != 3:
            continue
        inst, tapes, library = parts
        tapes_stripped = tapes.strip()
        num_tapes = int(tapes_stripped) if tapes_stripped.isdigit() else 0
        inst_stripped = inst.strip()
        library_stripped = library.strip()
        if inst_stripped != "default":
            item = inst_stripped + " / " + library_stripped
        else:
            item = library_stripped
        section[item] = num_tapes

    # Discovery mode
    if params.get("_discover"):
        discovery_items = []
        for item, count in section.items():
            discovery_items.append({
                "item": item,
                "params": {"levels_lower": ("fixed", (7, 5))},
                "metrics": ["tapes_free"]
            })
        return {"changed": False, "msg": "discovered %d items" % len(discovery_items),
                "data": {"discovery": discovery_items}}

    # Check mode
    item = params.get("item", "")
    if item not in section:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    num_tapes = section[item]
    levels_lower = params.get("levels_lower", ("fixed", (7, 5)))
    
    state = "OK"
    if levels_lower[0] == "fixed":
        warn, crit = levels_lower[1]
        if num_tapes <= crit:
            state = "CRIT"
        elif num_tapes <= warn:
            state = "WARN"
    
    msg = "Found tapes: %d" % num_tapes
    if levels_lower[0] == "fixed":
        warn, crit = levels_lower[1]
        msg = msg + " (warn at %d, crit at %d)" % (warn, crit)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"tapes_free": num_tapes}, "details": ""}}