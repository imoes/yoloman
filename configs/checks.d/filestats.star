def main(ctx, params):
    if params.get("_discover"):
        pattern = "/var/log/*"
        res = ctx.run(["find", pattern, "-type", "f", "-printf", "%p\\t%Y\\t%s\\t%T@\\n"], mutates=False)
        files = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            path, ftype, size_str, mtime_str = parts[0], parts[1], parts[2], parts[3]
            if ftype != "y":
                continue
            size = int(size_str) if size_str.isdigit() else 0
            mtime = float(mtime_str) if mtime_str.replace(".", "").isdigit() else 0.0
            date_res = ctx.run(["date", "+%s"], mutates=False)
            now_str = date_res.stdout.strip()
            now = float(now_str) if now_str.isdigit() else 0.0
            age = now - mtime
            files.append({"path": path, "size": size, "age": age, "type": "file"})
        count = len(files)
        files.insert(0, {"type": "summary", "count": count})
        return {
            "changed": False,
            "msg": "discovered 1 file group",
            "data": {"discovery": [{"item": pattern, "params": {}, "metrics": ["file_count"]}]},
        }

    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(["find", item, "-type", "f", "-printf", "%p\\t%Y\\t%s\\t%T@\\n"], mutates=False)
    files = []
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        path, ftype, size_str, mtime_str = parts[0], parts[1], parts[2], parts[3]
        if ftype != "y":
            continue
        size = int(size_str) if size_str.isdigit() else 0
        mtime = float(mtime_str) if mtime_str.replace(".", "").isdigit() else 0.0
        date_res = ctx.run(["date", "+%s"], mutates=False)
        now_str = date_res.stdout.strip()
        now = float(now_str) if now_str.isdigit() else 0.0
        age = now - mtime
        files.append({"path": path, "size": size, "age": age, "type": "file"})

    if not files:
        return {
            "changed": False,
            "msg": "no files found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    count = len(files)
    size_values = [f["size"] for f in files if f.get("size") != None]
    age_values = [f["age"] for f in files if f.get("age") != None]

    warn_count_tuple = params.get("maxcount", (None, None))
    crit_count_tuple = params.get("mincount", (None, None))
    warn_count = warn_count_tuple[0] if warn_count_tuple else None
    crit_count = warn_count_tuple[1] if warn_count_tuple else None
    warn_count_lower = crit_count_tuple[0] if crit_count_tuple else None
    crit_count_lower = crit_count_tuple[1] if crit_count_tuple else None

    state = "OK"
    if crit_count != None and count >= crit_count:
        state = "CRIT"
    elif warn_count != None and count >= warn_count:
        state = "WARN"
    elif crit_count_lower != None and count <= crit_count_lower:
        state = "CRIT"
    elif warn_count_lower != None and count <= warn_count_lower:
        state = "WARN"

    metrics = {"file_count": count}
    details_parts = []
    if size_values:
        min_size = min(size_values)
        max_size = max(size_values)
        metrics["size_smallest"] = min_size
        metrics["size_largest"] = max_size
        details_parts.append("Smallest: %d, Largest: %d" % (min_size, max_size))
    if age_values:
        min_age = min(age_values)
        max_age = max(age_values)
        metrics["age_newest"] = min_age
        metrics["age_oldest"] = max_age
        details_parts.append("Newest: %d s, Oldest: %d s" % (min_age, max_age))

    details = ", ".join(details_parts) if details_parts else ""
    msg = "Files in total: %d" % count
    if details:
        msg = msg + ", " + details

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }
