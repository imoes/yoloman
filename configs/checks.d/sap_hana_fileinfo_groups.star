def _fnmatch(name, pattern):
    if "*" not in pattern and "?" not in pattern and "[" not in pattern:
        return name == pattern

    parts = pattern.split("*")
    if len(parts) == 1:
        if len(name) != len(pattern):
            return False
        for i in range(len(pattern)):
            p = pattern[i]
            n = name[i]
            if p == "?":
                continue
            if p == n:
                continue
            return False
        return True

    idx = 0
    for part in parts:
        if part == "":
            continue
        pos = name.find(part, idx)
        if pos == -1:
            return False
        idx = pos + len(part)
    if not pattern.endswith("*"):
        last_part = parts[-1]
        if last_part != "" and not name.endswith(last_part):
            return False
    return True

def _matches_patterns(name, include_patterns, exclude_patterns):
    matched = False
    for inc in include_patterns:
        if inc == "":
            continue
        if inc.startswith("~"):
            pattern = inc[1:]
            if _fnmatch(name, pattern):
                matched = True
        else:
            if _fnmatch(name, inc):
                matched = True
    if not matched:
        return False
    for exc in exclude_patterns:
        if exc == "":
            continue
        if exc.startswith("~"):
            pattern = exc[1:]
            if _fnmatch(name, pattern):
                return False
        else:
            if _fnmatch(name, exc):
                return False
    return True

def _stat_file(ctx, path):
    res = ctx.run(["stat", "-c", "%s %Y", path], mutates=False)
    if res.rc == 1:
        return {"exists": False, "missing": True, "failed": False, "size": None, "mtime": None}
    if res.rc != 0:
        return {"exists": False, "missing": False, "failed": True, "size": None, "mtime": None}

    out = res.stdout.strip()
    parts = out.split(" ")
    if len(parts) < 2:
        return {"exists": False, "missing": False, "failed": True, "size": None, "mtime": None}
    size_str = parts[0]
    mtime_str = parts[1]
    if not size_str.isdigit() or not mtime_str.isdigit():
        return {"exists": False, "missing": False, "failed": True, "size": None, "mtime": None}
    return {
        "exists": True,
        "missing": False,
        "failed": False,
        "size": int(size_str),
        "mtime": int(mtime_str),
    }

def _render_bytes(size):
    if size == None:
        return "?"
    units = ["B", "kB", "MB", "GB", "TB", "PB"]
    val = float(size)
    u = 0
    while val >= 1024 and u < len(units) - 1:
        val = val / 1024
        u = u + 1
    if u == 0:
        return "%d %s" % (int(val), units[u])
    return "%f %s" % (val, units[u])

def _render_timespan(seconds):
    if seconds == None:
        return "?"
    seconds = int(seconds)
    if seconds < 0:
        return "-" + _render_timespan(abs(seconds))
    days = seconds / 86400
    hours = (seconds % 86400) / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60
    if days >= 1:
        return "%dd %dh %dm" % (int(days), int(hours), int(minutes))
    elif hours >= 1:
        return "%dh %dm %ds" % (int(hours), int(minutes), int(secs))
    elif minutes >= 1:
        return "%dm %ds" % (int(minutes), int(secs))
    else:
        return "%ds" % int(secs)

def _check_levels(value, max_levels, min_levels):
    state = "OK"
    if max_levels != None and len(max_levels) == 2:
        warn, crit = max_levels
        if crit != None and value >= crit:
            state = "CRIT"
        elif warn != None and value >= warn:
            state = "WARN"
    if min_levels != None and len(min_levels) == 2:
        warn, crit = min_levels
        if crit != None and value <= crit:
            state = "CRIT"
        elif warn != None and value <= warn:
            state = "WARN"
    if max_levels != None and len(max_levels) == 2:
        warn, crit = max_levels
        if crit != None and value >= crit:
            state = "CRIT"
    if min_levels != None and len(min_levels) == 2:
        warn, crit = min_levels
        if crit != None and value <= crit:
            state = "CRIT"
    return state

def _max_state(s1, s2):
    priority = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if priority.get(s1, 3) >= priority.get(s2, 3):
        return s1
    return s2

def main(ctx, params):
    paths = params.get("paths", [])
    group_patterns = params.get("group_patterns", [])

    if params.get("_discover"):
        if len(paths) == 0:
            return {"changed": False, "msg": "no file paths configured",
                    "data": {"discovery": []}}

        res = ctx.run(["date", "+%s"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "cannot determine reftime",
                    "data": {"discovery": []}}
        reftime = int(res.stdout.strip())

        file_items = {}
        for path in paths:
            name = path.split("/")[-1] if "/" in path else path
            stat_res = _stat_file(ctx, path)
            if stat_res["exists"]:
                file_items[name] = {
                    "name": name,
                    "missing": False,
                    "failed": False,
                    "size": stat_res["size"],
                    "time": stat_res["mtime"],
                }

        if len(file_items) == 0:
            return {"changed": False, "msg": "no files found",
                    "data": {"discovery": []}}

        discovery = []
        seen_groups = {}
        for fi in file_items.values():
            for gp in group_patterns:
                group_name = gp.get("group_name", "")
                include = gp.get("include", "*")
                exclude = gp.get("exclude", "")

                include_patterns = [include] if include else []
                exclude_patterns = [exclude] if exclude else []

                if _matches_patterns(fi["name"], include_patterns, exclude_patterns):
                    if group_name not in seen_groups:
                        seen_groups[group_name] = {
                            "include": include,
                            "exclude": exclude,
                        }

        metrics_list = ["count", "size", "size_largest", "size_smallest", "age_oldest", "age_newest"]
        for group_name, patterns in seen_groups.items():
            discovery.append({
                "item": group_name,
                "params": {
                    "group_patterns": [{
                        "group_pattern_include": patterns["include"],
                        "group_pattern_exclude": patterns["exclude"],
                    }],
                },
                "metrics": metrics_list,
            })

        return {"changed": False,
                "msg": "discovered %d file groups" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    group_patterns = params.get("group_patterns", [])

    if len(group_patterns) == 0:
        return {"changed": False,
                "msg": "No group pattern found.",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    include_patterns = []
    exclude_patterns = []
    for p in group_patterns:
        inc = p.get("group_pattern_include", "")
        exc = p.get("group_pattern_exclude", "")
        if inc:
            include_patterns.append(inc)
        if exc:
            exclude_patterns.append(exc)

    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "Cannot determine reftime",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    reftime = int(res.stdout.strip())

    if len(paths) == 0:
        return {"changed": False,
                "msg": "No file paths configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    files_matching = {
        "count_all": 0,
        "size_all": 0,
        "size_minmax": None,
        "age_minmax": None,
    }
    files_stat_failed = []
    details = []

    for path in paths:
        name = path.split("/")[-1] if "/" in path else path
        stat_res = _stat_file(ctx, path)

        if not stat_res["exists"]:
            if stat_res["missing"]:
                continue
            if stat_res["failed"]:
                files_stat_failed.append(name)
                continue

        if not _matches_patterns(name, include_patterns, exclude_patterns):
            continue

        if stat_res["failed"]:
            files_stat_failed.append(name)
            continue

        if stat_res["size"] == None or stat_res["time"] == None:
            continue

        files_matching["count_all"] += 1
        files_matching["size_all"] += stat_res["size"]

        sm = files_matching["size_minmax"]
        if sm == None:
            files_matching["size_minmax"] = (stat_res["size"], stat_res["size"])
        else:
            files_matching["size_minmax"] = (min(sm[0], stat_res["size"]), max(sm[1], stat_res["size"]))

        age = reftime - stat_res["time"]
        am = files_matching["age_minmax"]
        if am == None:
            files_matching["age_minmax"] = (age, age)
        else:
            files_matching["age_minmax"] = (min(am[0], age), max(am[1], age))

        size_str = _render_bytes(stat_res["size"])
        age_str = _render_timespan(abs(age))
        if age < 0:
            details.append("[%s] Age: -%s, Size: %s (future timestamp)" % (name, age_str, size_str))
        else:
            details.append("[%s] Age: %s, Size: %s" % (name, age_str, size_str))

    size_smallest = None
    size_largest = None
    age_newest = None
    age_oldest = None
    if files_matching["size_minmax"] != None:
        size_smallest, size_largest = files_matching["size_minmax"]
    if files_matching["age_minmax"] != None:
        age_newest, age_oldest = files_matching["age_minmax"]

    count_val = files_matching["count_all"]
    size_all_val = files_matching["size_all"]

    metrics = {}
    overall_state = "OK"
    summary_parts = []

    max_count = params.get("maxcount", None)
    min_count = params.get("mincount", None)
    if max_count != None and len(max_count) == 2:
        cw, cc = max_count
        if cc != None and count_val >= cc:
            overall_state = _max_state(overall_state, "CRIT")
        elif cw != None and count_val >= cw:
            overall_state = _max_state(overall_state, "WARN")
    if min_count != None and len(min_count) == 2:
        cw, cc = min_count
        if cc != None and count_val <= cc:
            overall_state = _max_state(overall_state, "CRIT")
        elif cw != None and count_val <= cw:
            overall_state = _max_state(overall_state, "WARN")
    metrics["count"] = count_val
    summary_parts.append("Count: %d" % count_val)

    for title, key, val in [("Size", "size", size_all_val),
                            ("Largest size", "size_largest", size_largest),
                            ("Smallest size", "size_smallest", size_smallest),
                            ("Oldest age", "age_oldest", age_oldest),
                            ("Newest age", "age_newest", age_newest)]:
        vk = "max" + key
        nk = "min" + key
        mval = params.get(vk, None)
        nlval = params.get(nk, None)

        if val != None:
            metrics[key] = val
            if "age" in title.lower() and val < 0:
                tolerance = params.get("negative_age_tolerance", 0)
                if abs(val) <= tolerance:
                    pass
                else:
                    s = _max_state(overall_state, "UNKNOWN")
                    age_str = _render_timespan(abs(val))
                    summary_parts.append("%s: -%s (future timestamp)" % (title, age_str))
                    overall_state = s

            st = _check_levels(val, mval, nlval)
            overall_state = _max_state(overall_state, st)
            if "size" in title.lower():
                readable = _render_bytes(val)
            else:
                readable = _render_timespan(abs(val))
            summary_parts.append("%s: %s" % (title, readable))

    if include_patterns:
        summary_parts.append("Include: %s" % ", ".join(include_patterns))
    if exclude_patterns:
        summary_parts.append("Exclude: %s" % ", ".join(exclude_patterns))

    if files_stat_failed:
        summary_parts.append("Failed: %s" % ", ".join(files_stat_failed))
        overall_state = _max_state(overall_state, "WARN")

    msg = ", ".join(summary_parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": metrics,
            "details": "\n".join(details),
        },
    }