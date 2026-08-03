_ABBREVIATIONS = {
    "awb": "Always WriteBack",
    "b": "Blocked",
    "cac": "CacheCade",
    "cbshld": "Copyback Shielded",
    "c": "Cached IO",
    "cfshld": "Configured shielded",
    "consist": "Consistent",
    "cpybck": "CopyBack",
    "dg": "Drive Group",
    "dgrd": "Degraded",
    "dhs": "Dedicated Hot Spare",
    "did": "Device ID",
    "eid": "Enclosure Device ID",
    "f": "Foreign",
    "ghs": "Global Hot Spare",
    "hd": "Hidden",
    "hspshld": "Hot Spare shielded",
    "intf": "Interface",
    "med": "Media Type",
    "nr": "No Read Ahead",
    "offln": "Offline",
    "ofln": "OffLine",
    "onln": "Online",
    "optl": "Optimal",
    "pdgd": "Partially Degraded",
    "pi": "Protection Info",
    "rec": "Recovery",
    "ro": "Read Only",
    "r": "Read Ahead Always",
    "rw": "Read Write",
    "scc": "Scheduled Check Consistency",
    "sed": "Self Encryptive Drive",
    "sesz": "Sector Size",
    "slt": "Slot No.",
    "sp": "Spun",
    "trans": "TransportReady",
    "t": "Transition",
    "ubad": "Unconfigured Bad",
    "ubunsp": "Unconfigured Bad Unsupported",
    "ugood": "Unconfigured Good",
    "ugshld": "Unconfigured shielded",
    "ugunsp": "Unsupported",
    "u": "Up",
    "vd": "Virtual Drive",
    "wb": "WriteBack",
    "wt": "WriteThrough",
}

LDISKS_DEFAULTS = {
    "Optimal": 0,
    "Partially Degraded": 1,
    "Degraded": 2,
    "Offline": 1,
    "Recovery": 1,
}

STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def expand_abbreviation(short):
    return _ABBREVIATIONS.get(short.lower(), short)


def parse_vdrives(output):
    section = {}
    controller_num = 0
    separator_count = 0

    lines = output.splitlines()
    data_lines = []

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("-----"):
            separator_count += 1
            if separator_count == 3:
                separator_count = 0
                controller_num += 1
        elif separator_count == 2:
            data_lines.append((controller_num, line))

    for controller_num, line in data_lines:
        f = line.split()
        if len(f) < 5:
            continue
        dg_vd = f[0]
        raid_type = f[1]
        rawstate = f[2]
        access = f[3]
        consistent = f[4]
        section["C%d.%s" % (controller_num, dg_vd)] = {
            "raid_type": raid_type,
            "state": expand_abbreviation(rawstate),
            "access": access,
            "consistent": consistent == "Yes",
        }

    return section


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["storcli64", "show"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "storcli not available", "data": {"discovery": []}}

        out = []
        for ctrl in range(0, 16):
            ctrl_res = ctx.run(["storcli64", "/c%d" % ctrl, "show"], mutates=False)
            if ctrl_res.rc != 0:
                break

            vd_res = ctx.run(["storcli64", "/c%d" % ctrl, "vdrv", "show", "all"], mutates=False)
            if vd_res.rc != 0:
                continue

            section = parse_vdrives(vd_res.stdout)
            for item in section:
                out.append({
                    "item": item,
                    "params": dict(LDISKS_DEFAULTS),
                    "metrics": [],
                })

        if len(out) == 0:
            return {"changed": False, "msg": "no virtual drives found", "data": {"discovery": []}}

        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["storcli64", "show"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "storcli not available on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Determine which controller this item belongs to
    # item is "C<controller>.<dg/vd>"
    parts = item.split(".")
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "invalid item format: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    ctrl_str = parts[0]
    # ctrl_str is like "C0"
    if not ctrl_str.startswith("C"):
        return {
            "changed": False,
            "msg": "invalid controller in item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    ctrl_num = ctrl_str[1:]
    if not ctrl_num.isdigit():
        return {
            "changed": False,
            "msg": "invalid controller number: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    vd_res = ctx.run(["storcli64", "/c%s" % ctrl_num, "vdrv", "show", "all"], mutates=False)
    if vd_res.rc != 0:
        return {
            "changed": False,
            "msg": "no virtual drives found for controller %s" % ctrl_num,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = parse_vdrives(vd_res.stdout)
    if item not in section:
        return {
            "changed": False,
            "msg": "virtual drive not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    drive = section[item]
    details_lines = []
    details_lines.append("Raid type is %s" % drive["raid_type"])
    details_lines.append("Access: %s" % drive["access"])

    if not drive["consistent"]:
        details_lines.append("Drive is not consistent")

    summary = "State is %s" % drive["state"]

    raw_state = params.get(drive["state"])
    if raw_state == None:
        state = "UNKNOWN"
        summary += " (unknown[%s])" % drive["state"]
    else:
        state_num = raw_state
        state = STATE_NAMES.get(state_num, "UNKNOWN")

    details = "\n".join(details_lines)

    return {
        "changed": False,
        "msg": "%s" % summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }