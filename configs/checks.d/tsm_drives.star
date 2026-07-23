def main(ctx, params):
    # Discovery mode: enumerate all TSM drives
    if params.get("_discover"):
        drives = []
        # Attempt to read the tsm_drives data
        res = ctx.run(["bash", "-c", "cat"], mutates=False)
        if res.rc == 0:
            for line in res.stdout.splitlines():
                parts = line.strip().split()
                if len(parts) >= 5:
                    inst, library, drive = parts[0], parts[1], parts[2]
                    item = library + " / " + drive
                    if inst != "default":
                        item = inst + " / " + item
                    drives.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d drives" % len(drives),
                "data": {"discovery": drives}}

    # Check mode: verify one specific drive
    item = params.get("item", "")

    # Read raw data
    res = ctx.run(["bash", "-c", "cat"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "drive not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found = False
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 5:
            continue

        # Handle both 6-column and 5-column formats
        if len(parts) == 6:
            inst, library, drive, state, online, serial = parts
        elif len(parts) == 5:
            inst, library, drive, state, online = parts
            serial = ""
        else:
            continue

        libdev = library + " / " + drive
        check_item1 = libdev
        check_item2 = inst + " / " + libdev
        if item != check_item1 and item != check_item2:
            continue

        # Build info text
        infotext = ""
        if serial != "":
            infotext = "[" + serial + "] "

        state = state.upper()
        online = online.upper()
        monstate = "OK"

        infotext = infotext + "state: " + state
        if state == "UNAVAILABLE" or state == "UNKNOWN":
            monstate = "CRIT"
            infotext = infotext + " (!!)"

        infotext = infotext + ", online: " + online
        if online != "YES":
            monstate = "CRIT"
            infotext = infotext + " (!!)"

        found = True
        return {"changed": False, "msg": infotext,
                "data": {"state": monstate, "metrics": {}, "details": ""}}

    if not found:
        return {"changed": False, "msg": "drive not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}