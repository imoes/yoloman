def main(ctx, params):
    if params.get("_discover"):
        return discovery(ctx)
    return check(ctx, params)


# ----- data gathering -----

def gather_multipath(ctx):
    """Run multipath -ll and parse into a dict keyed by UUID.

    Returns {"groups": {uuid: group}, "present": bool}
    group = {"alias", "uuid", "numpaths", "broken", "active", "paths", "state"}
    """
    # Probe for the real thing first.
    ver = ctx.run(["multipath", "-v", "1"], mutates=False)
    if ver.rc == 127:
        return {"groups": {}, "present": False}

    res = ctx.run(["multipath", "-ll"], mutates=False)
    if res.rc != 0:
        return {"groups": {}, "present": False}

    groups = {}
    present = False
    uuid = None
    alias = None
    dm_device = None
    numpaths = 0
    lun_info = []
    paths_info = []
    broken_paths = []
    state = None
    cur = {}

    # REG_LUN = [0-9]+:[0-9]+:[0-9]+:[0-9]+
    # REG_PRIO marker: "[ ]prio="
    for raw_line in res.stdout.splitlines():
        line = raw_line.split()
        if len(line) == 0:
            continue

        if line[0] == "multipath.conf":
            continue

        if line[0] == "dm":
            uuid = None
            continue

        l = " ".join(line)

        # Skip output when multipath is not present
        if (
            l.endswith("kernel driver not loaded")
            or l.endswith("does not exist, blacklisting all devices.")
            or l.endswith("A sample multipath.conf file is located at")
            or l.endswith("multipath.conf")
        ):
            uuid = None
            continue

        # data row vs header row
        is_data = (
            len(line[0]) > 0
            and line[0][0] in ["[", "`", "|", "\\"]
        ) or line[0].startswith("size=")

        if not is_data:
            # header row — match against REG_HEADERS in order
            uuid_m = None
            alias_m = None
            dm_m = None
            matched = False

            # 1. 33 hex chars
            if len(l) == 33 and _is_hex(l):
                uuid_m = l
                matched = True
            # 2. "name (alias) dm-X"
            elif not matched:
                m = _match_header2(l)
                if m != None:
                    uuid_m = m[0]
                    alias_m = m[1]
                    dm_m = m[2]
                    matched = True
            # 3. "name (alias)"
            if not matched:
                m = _match_header3(l)
                if m != None:
                    uuid_m = m[0]
                    alias_m = m[1]
                    matched = True
            # 4. 33 or 49 hex + dm-X
            if not matched:
                m = _match_header4(l)
                if m != None:
                    uuid_m = m[0]
                    dm_m = m[1]
                    matched = True
            # 5. name + dm-X  (legacy)
            if not matched:
                m = _match_header5(l)
                if m != None:
                    uuid_m = l
                    dm_m = m
                    matched = True
            # 6/7. "name dm-X"
            if not matched:
                m = _match_header67(l)
                if m != None:
                    uuid_m = m[0]
                    dm_m = m[1]
                    matched = True

            if not matched:
                continue

            uuid = uuid_m.strip() if uuid_m != None else None
            alias = alias_m if alias_m != None else None
            dm_device = dm_m if dm_m != None else None

            numpaths = 0
            lun_info = []
            paths_info = []
            broken_paths = []
            state = None

            cur = {
                "paths": paths_info,
                "broken": broken_paths,
                "luns": lun_info,
                "uuid": uuid,
                "state": state,
                "numpaths": numpaths,
                "device": dm_device,
                "alias": alias if alias != None else None,
            }
            if uuid != None:
                groups[uuid] = cur
            present = True
            continue

        # data row
        if uuid == None:
            continue

        if line[0] == "|":
            line = line[1:]
        if len(line) == 0:
            continue

        if _has_prio(l):
            if len(line) >= 4:
                cur["state"] = " ".join(line[3:])
        elif len(line) >= 4 and _is_lun(line[1]):
            luninfo = line[1] + "(" + line[2] + ")"
            lun_info.append(luninfo)
            cur["numpaths"] = cur["numpaths"] + 1
            paths_info.append(line[2])
            pstate = line[4] if len(line) >= 5 else ""
            if "active" not in pstate:
                broken_paths.append(luninfo)

    # finalize numpaths
    for g in groups.values():
        np = 0
        broken = 0
        for idx in range(len(g["paths"])):
            np = np + 1
        for idx in range(len(g["broken"])):
            broken = broken + 1
        g["numpaths"] = np
        g["num_active"] = np - broken

    return {"groups": groups, "present": present}


# ----- header / pattern helpers (string-based, no regex) -----

def _is_hex(s):
    if len(s) == 0:
        return False
    for c in s:
        if c not in "0123456789abcdefABCDEF":
            return False
    return True


def _match_header2(l):
    # pattern: r"^([^\s]+)\s\(([^)]+)\)\s(dm.[0-9]+)"
    sp = l.find(" ")
    if sp == -1:
        return None
    first = l[:sp]
    rest = l[sp + 1:]
    if len(rest) < 2:
        return None
    if rest[0] != "(":
        return None
    cp = rest.find(")", 1)
    if cp == -1:
        return None
    alias = rest[1:cp]
    after = rest[cp + 1:]
    if len(after) < 1 or after[0] != " ":
        return None
    after = after[1:]
    if not after.startswith("dm"):
        return None
    digit_part = after[2:]
    digits = ""
    for c in digit_part:
        if c in "0123456789":
            digits = digits + c
        else:
            break
    if len(digits) == 0:
        return None
    return (first, alias, after[:2 + len(digits)])


def _match_header3(l):
    # pattern: r"^([^\s]+)\s\(([^)]+)\)"
    sp = l.find(" ")
    if sp == -1:
        return None
    first = l[:sp]
    rest = l[sp + 1:]
    if len(rest) < 2:
        return None
    if rest[0] != "(":
        return None
    cp = rest.find(")", 1)
    if cp == -1:
        return None
    alias = rest[1:cp]
    return (first, alias)


def _match_header4(l):
    # pattern: r"^([0-9a-z]{33}|[0-9a-z]{49})\s?(dm.[0-9]+).*$"
    if len(l) < 33:
        return None
    seg = l[:33]
    if not _is_hex(seg):
        return None
    rest = l[33:]
    if len(rest) <= 0 or rest[0] != " ":
        if len(rest) > 0 and rest[0] != "d":
            return None
    dm = ""
    if len(rest) > 0 and rest[0] == " ":
        rest2 = rest[1:]
    else:
        rest2 = rest
    if not rest2.startswith("dm"):
        return None
    digit_part = rest2[2:]
    digits = ""
    for c in digit_part:
        if c in "0123456789":
            digits = digits + c
        else:
            break
    if len(digits) == 0:
        return None
    return (seg, "dm" + digits)


def _match_header5(l):
    # pattern: r"^[a-zA-Z0-9_]+(dm-[0-9]+).*$"  (legacy, returns dm device)
    sp = l.find(" ")
    if sp == -1:
        return None
    rest = l[sp + 1:]
    if not rest.startswith("dm-"):
        return None
    digit_part = rest[3:]
    digits = ""
    for c in digit_part:
        if c in "0123456789":
            digits = digits + c
        else:
            break
    if len(digits) == 0:
        return None
    return "dm-" + digits


def _match_header67(l):
    # pattern: r"^([-.a-zA-Z0-9_ :]+)\s?(dm-[0-9]+).*$"
    sp = l.find(" ")
    if sp == -1:
        return None
    first = l[:sp]
    after = l[sp + 1:]
    if not after.startswith("dm-"):
        return None
    digit_part = after[3:]
    digits = ""
    for c in digit_part:
        if c in "0123456789":
            digits = digits + c
        else:
            break
    if len(digits) == 0:
        return None
    return (first, "dm-" + digits)


def _has_prio(l):
    return ("prio=" in l) or ("[ prio=" in l)


def _is_lun(s):
    parts = s.split(":")
    if len(parts) != 4:
        return False
    for p in parts:
        if len(p) == 0:
            return False
        for c in p:
            if c not in "0123456789":
                return False
    return True


# ----- discovery -----

def discovery(ctx):
    data = gather_multipath(ctx)
    if not data["present"]:
        return {"changed": False, "msg": "multipath not present",
                "data": {"discovery": []}}

    use_alias = params_get_bool("use_alias", False, ctx._params if hasattr(ctx, "_params") else None)

    out = []
    groups = data["groups"]
    for uuid in groups:
        g = groups[uuid]
        if use_alias and g["alias"] != None:
            item = g["alias"]
        else:
            item = uuid
        metrics = ["active_percent"]
        out.append({
            "item": item,
            "params": {"levels": (50, 100)},
            "metrics": metrics,
        })
    return {"changed": False,
            "msg": "discovered %d multipath devices" % len(out),
            "data": {"discovery": out}}


def params_get_bool(key, default, params):
    if params == None:
        return default
    v = params.get(key)
    if v == None:
        return default
    if type(v) == "bool":
        return v
    return default


# ----- check -----

def check(ctx, params):
    item = params.get("item", "")
    levels = params.get("levels")
    if type(levels) == "list":
        warn = levels[0] if len(levels) > 0 else 50
        crit = levels[1] if len(levels) > 1 else 100
    elif type(levels) == "string":
        warn = 50
        crit = 100
    else:
        warn = 50
        crit = 100

    data = gather_multipath(ctx)
    if not data["present"]:
        return {"changed": False,
                "msg": "multipath not found on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    groups = data["groups"]
    g = None
    found_by_alias = False

    if item in groups:
        g = groups[item]
    else:
        for uuid in groups:
            gg = groups[uuid]
            if gg["alias"] == item:
                g = gg
                found_by_alias = True
                break

    if g == None:
        return {"changed": False,
                "msg": "multipath device not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    num_paths = g["numpaths"]
    num_broken = len(g["broken"])
    num_active = num_paths - num_broken

    if g["uuid"] != None and g["alias"] != None and item == g["uuid"]:
        aliasinfo = "(" + g["alias"] + "): "
    elif g["alias"] != None and g["uuid"] != None and item == g["alias"]:
        aliasinfo = "(" + g["uuid"] + "): "
    else:
        aliasinfo = ""

    if num_paths == 0:
        return {"changed": False,
                "msg": aliasinfo + "No paths",
                "data": {"state": "CRIT", "metrics": {"active_percent": 0},
                         "details": "no paths for this multipath device"}}

    active_percent = (num_active / num_paths) * 100.0

    state = "OK"
    if active_percent >= crit:
        state = "CRIT"
    elif active_percent >= warn:
        state = "WARN"

    summary = aliasinfo + "%d of %d paths active (%d%%)" % (num_active, num_paths, int(active_percent))

    metric_val = active_percent

    details_lines = ["Paths active: %d of %d" % (num_active, num_paths),
                     "Active: %d%%" % int(active_percent)]
    broken_list = ", ".join(g["broken"])
    if len(g["broken"]) > 0:
        details_lines.append("Broken paths: " + broken_list)
    details = "\n".join(details_lines)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"active_percent": metric_val},
            "details": details,
        },
    }