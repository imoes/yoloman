def main(ctx, params):
    # TSM drive check — reads drive/library status via dsmadmc
    # The real data source is the TSM server queried through dsmadmc CLI

    if params.get("_discover"):
        # Probe for dsmadmc first
        probe = ctx.run(["dsmadmc", "-version"], mutates=False)
        if probe.rc == 127:
            # dsmadmc not installed — TSM not present on this host
            return {"changed": False, "msg": "no TSM client found", "data": {"discovery": []}}
        if probe.rc != 0:
            return {"changed": False, "msg": "dsmadmc not available", "data": {"discovery": []}}

        # Query all drives with full detail
        res = ctx.run(["dsmadmc", "query", "drive"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "dsmadmc query drive failed", "data": {"discovery": []}}

        out = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Skip header lines
            if line.startswith("IBM") or line.startswith("Tivoli") or "TSM" in line:
                continue
            if line.startswith("Drive") and "State" in line:
                continue
            f = line.split()
            # Expected: inst library drive state online [volume]
            if len(f) < 5:
                continue
            # Filter: state should be a known state word
            if f[3] not in ("LOADED", "EMPTY", "UNAVAILABLE", "UNLOADED", "RESERVED", "UNKNOWN"):
                continue
            inst = f[0]
            library = f[1]
            drive = f[2]
            item = library + " / " + drive
            if inst != "default":
                item = inst + " / " + item
            out.append({"item": item, "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d TSM drives" % len(out),
                "data": {"discovery": out}}

    # Check mode — check one specific drive
    item = params.get("item", "")

    # Probe for dsmadmc
    probe = ctx.run(["dsmadmc", "-version"], mutates=False)
    if probe.rc == 127 or probe.rc != 0:
        return {"changed": False,
                "msg": "no TSM client (dsmadmc) found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "dsmadmc not installed"}}

    res = ctx.run(["dsmadmc", "query", "drive", item], mutates=False)
    # Actually, dsmadmc query drive takes a drive name, not our formatted item
    # Let me reconsider the query approach...

    found = False
    infotext = ""
    monstate = "OK"
    details = ""

    # Parse through query drive output to find matching item
    res = ctx.run(["dsmadmc", "query", "drive"], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "dsmadmc query drive failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("IBM") or line.startswith("Tivoli") or "TSM" in line:
            continue
        if line.startswith("Drive") and ("State" in line or "Library" in line):
            continue
        f = line.split()
        if len(f) < 5:
            continue
        if f[3] not in ("LOADED", "EMPTY", "UNAVAILABLE", "UNLOADED", "RESERVED", "UNKNOWN"):
            continue

        inst = f[0]
        library = f[1]
        drive = f[2]
        state = f[3]
        online = f[4]
        vol = f[5] if len(f) >= 6 else ""

        libdev = library + " / " + drive
        match_item = libdev if inst == "default" else inst + " / " + libdev

        if match_item == item:
            found = True
            infotext = "[" + vol + "] " if vol else ""
            infotext += "state: " + state
            if state in ("UNAVAILABLE", "UNKNOWN"):
                monstate = "CRIT"
                infotext += "(!!)"
            infotext += ", online: " + online
            if online != "YES":
                monstate = "CRIT"
                infotext += "(!!)"
            details = line
            break

    if not found:
        return {"changed": False,
                "msg": "drive not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {"changed": False,
            "msg": infotext,
            "data": {"state": monstate, "metrics": {}, "details": details}}