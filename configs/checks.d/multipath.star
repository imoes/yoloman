def _re_match(pattern, text):
    # Simple regex matcher using Starlark string methods
    return text.find(pattern) != -1

def _is_uuid_candidate(s):
    if len(s) != 33 and len(s) != 49:
        return False
    for c in s:
        if c not in "0123456789abcdef":
            return False
    return True

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["multipath", "-l"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "multipath command failed",
                    "data": {"discovery": []}}

        section = {}
        uuid = None
        alias = None
        groups = {}
        group = {}

        for line in res.stdout.splitlines():
            l = line.strip()
            if not l:
                continue

            # Skip multipath.conf errors
            if l.startswith("multipath.conf") or l.find("kernel driver not loaded") != -1 or l.find("does not exist") != -1:
                uuid = None
                continue

            # Skip dm table lines
            if l.find("dm ") == 0:
                uuid = None
                continue

            # Detect header lines
            is_header = False

            # Pattern: "alias (UUID)" or "alias (UUID) dm-X"
            if l.find("(") != -1 and l.find(")") != -1:
                idx1 = l.find("(")
                alias_candidate = l[:idx1].strip()
                rest = l[idx1+1:]
                idx2 = rest.find(")")
                if idx2 != -1:
                    uuid_candidate = rest[:idx2]
                    if _is_uuid_candidate(uuid_candidate.lower()):
                        uuid = uuid_candidate
                        alias = alias_candidate
                        is_header = True
                        # Check for dm-X suffix after the closing parenthesis
                        after = rest[idx2+1:].strip()
                        if after.find("dm-") == 0:
                            # Extract dm-X part
                            dm_part = after.split()[0] if after.split() else after
                            if dm_part.find("dm-") == 0:
                                alias = dm_part

            # Pattern: UUID with optional dm-X suffix (no parentheses)
            if not is_header:
                parts = l.split()
                if len(parts) > 0:
                    first = parts[0]
                    if (len(first) == 33 or len(first) == 49) and _is_uuid_candidate(first.lower()):
                        uuid = first
                        alias = l
                        is_header = True
                        if len(parts) > 1:
                            for p in parts[1:]:
                                if p.find("dm-") == 0:
                                    alias = p
                                    break

            if is_header:
                group = {
                    "paths": [],
                    "broken_paths": [],
                    "luns": [],
                    "uuid": uuid,
                    "state": None,
                    "numpaths": 0,
                    "device": None,
                    "alias": alias
                }
                if uuid != None:
                    groups[uuid] = group
                continue

            # Skip header lines
            if not uuid or l.find("|") != 0 and l.find("`") != 0 and l.find(" ") != 0 and l.find("[") != 0 and l.find("\\") != 0:
                continue

            # Skip state lines
            if l.find("prio=") != -1:
                continue

            # Process path lines
            tokens = l.split()
            if len(tokens) >= 4 and tokens[0].find(":") != -1 and tokens[0].count(":") == 3:
                lun_info = tokens[0] + "(" + tokens[1] + ")"
                state_text = ""
                for i in range(3, len(tokens)):
                    if i > 3:
                        state_text += " "
                    state_text += tokens[i]
                if state_text.find("active") == -1:
                    group["broken_paths"].append(lun_info)
                group["numpaths"] += 1
                group["paths"].append(tokens[1])
                group["luns"].append(lun_info)
                group["device"] = "dm-" + str(len(group["paths"]))

        # Build discovery list
        out = []
        for uuid_key, g in groups.items():
            use_alias = params.get("use_alias", False)
            item = g["alias"]
            if g["alias"] == None or not use_alias:
                item = uuid_key
            out.append({
                "item": item,
                "params": {"use_alias": use_alias},
                "metrics": ["paths_active_percent"]
            })

        return {"changed": False, "msg": "discovered %d multipath devices" % len(out),
                "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    use_alias = params.get("use_alias", False)

    res = ctx.run(["multipath", "-l"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "multipath command failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    groups = {}
    uuid = None
    alias = None

    for line in res.stdout.splitlines():
        l = line.strip()
        if not l:
            continue

        if l.find("multipath.conf") == 0 or l.find("kernel driver not loaded") != -1 or l.find("does not exist") != -1:
            uuid = None
            continue

        if l.find("dm ") == 0:
            uuid = None
            continue

        is_header = False

        if l.find("(") != -1 and l.find(")") != -1:
            idx1 = l.find("(")
            alias_candidate = l[:idx1].strip()
            rest = l[idx1+1:]
            idx2 = rest.find(")")
            if idx2 != -1:
                uuid_candidate = rest[:idx2]
                if _is_uuid_candidate(uuid_candidate.lower()):
                    uuid = uuid_candidate
                    alias = alias_candidate
                    is_header = True
                    after = rest[idx2+1:].strip()
                    if after.find("dm-") == 0:
                        dm_part = after.split()[0] if after.split() else after
                        if dm_part.find("dm-") == 0:
                            alias = dm_part

        if not is_header:
            parts = l.split()
            if len(parts) > 0:
                first = parts[0]
                if (len(first) == 33 or len(first) == 49) and _is_uuid_candidate(first.lower()):
                    uuid = first
                    alias = l
                    is_header = True
                    if len(parts) > 1:
                        for p in parts[1:]:
                            if p.find("dm-") == 0:
                                alias = p
                                break

        if is_header:
            group = {
                "paths": [],
                "broken_paths": [],
                "luns": [],
                "uuid": uuid,
                "state": None,
                "numpaths": 0,
                "device": None,
                "alias": alias
            }
            if uuid != None:
                groups[uuid] = group
            continue

        if not uuid or l.find("|") != 0 and l.find("`") != 0 and l.find(" ") != 0 and l.find("[") != 0 and l.find("\\") != 0:
            continue

        if l.find("prio=") != -1:
            continue

        tokens = l.split()
        if len(tokens) >= 4 and tokens[0].find(":") != -1 and tokens[0].count(":") == 3:
            lun_info = tokens[0] + "(" + tokens[1] + ")"
            state_text = ""
            for i in range(3, len(tokens)):
                if i > 3:
                    state_text += " "
                state_text += tokens[i]
            if state_text.find("active") == -1:
                group["broken_paths"].append(lun_info)
            group["numpaths"] += 1
            group["paths"].append(tokens[1])
            group["luns"].append(lun_info)
            group["device"] = "dm-" + str(len(group["paths"]))

    # Find item
    mmap = None
    if item in groups:
        mmap = groups[item]
    else:
        for g in groups.values():
            if g["alias"] == item:
                mmap = g
                break

    if mmap == None:
        return {"changed": False, "msg": "multipath device not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build alias info
    aliasinfo = ""
    if item == mmap["uuid"] and mmap["alias"] != None:
        aliasinfo = "(%s): " % mmap["alias"]
    elif item == mmap["alias"] and mmap["uuid"] != None:
        aliasinfo = "(%s): " % mmap["uuid"]

    broken_paths = mmap["broken_paths"]
    num_paths = mmap["numpaths"]
    num_broken = len(broken_paths)
    num_active = num_paths - num_broken

    # Path active percentage
    paths_pct = 0.0
    if num_paths > 0:
        paths_pct = num_active * 100.0 / num_paths

    # Levels from params
    levels = params.get("levels")
    warn_level = 70.0
    crit_level = 50.0
    if levels != None:
        if type(levels) == "list" and len(levels) >= 2:
            warn_level = levels[0]
            crit_level = levels[1]

    # Determine state
    state = "OK"
    if num_paths == 0:
        state = "CRIT"
    elif paths_pct < crit_level:
        state = "CRIT"
    elif paths_pct < warn_level:
        state = "WARN"

    # Build message
    summary = ""
    if num_paths == 0:
        summary = aliasinfo + "No paths"
    else:
        summary = "%sPaths active: %f%%" % (aliasinfo, paths_pct)

    # Expected vs actual
    target = num_paths
    alert_level = "WARN"
    if levels != None:
        target = int(num_paths * warn_level / 100.0)
        alert_level = "WARN"

    infotext = "%d of %d (expected: %d)" % (num_active, num_paths, target)

    if num_broken > 0:
        summary = summary + "; Broken paths: " + ",".join(broken_paths)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"paths_active_percent": paths_pct},
            "details": infotext
        }
    }