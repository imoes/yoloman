def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["pgrep", "-x", "nullmailer"], mutates=False)
        if probe.rc != 0 and probe.rc != 1:
            return {"changed": False, "msg": "no nullmailer process found",
                    "data": {"discovery": []}}
        if probe.rc == 1 or len(probe.stdout.splitlines()) == 0:
            return {"changed": False, "msg": "no nullmailer process found",
                    "data": {"discovery": []}}
        queue_dir = "/var/spool/nullmailer/queue"
        st = ctx.stat(queue_dir)
        if not st or not st.get("is_dir"):
            return {"changed": False, "msg": "nullmailer queue directory not found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"deferred": (10, 20), "failed": (1, 1)},
                     "metrics": ["deferred_length", "deferred_size",
                                 "failed_length", "failed_size"]}]}}

    item = params.get("item", "")
    probe = ctx.run(["pgrep", "-x", "nullmailer"], mutates=False)
    if probe.rc != 0 and probe.rc != 1:
        return {"changed": False, "msg": "no nullmailer process found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no nullmailer process"}}
    if probe.rc == 1 or len(probe.stdout.splitlines()) == 0:
        return {"changed": False, "msg": "no nullmailer process found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no nullmailer process"}}

    queue_dir = "/var/spool/nullmailer/queue"
    st = ctx.stat(queue_dir)
    if not st or not st.get("is_dir"):
        return {"changed": False, "msg": "nullmailer queue directory not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "queue dir missing"}}

    deferred_size = 0
    deferred_count = 0
    failed_size = 0
    failed_count = 0

    queue_subdir = ctx.stat(queue_dir)
    if not queue_subdir:
        return {"changed": False, "msg": "cannot stat queue directory",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "stat failed"}}

    list_res = ctx.run(["ls", "-1A", queue_dir], mutates=False)
    if list_res.rc != 0:
        return {"changed": False, "msg": "cannot list queue directory",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "ls failed"}}

    for subdir in list_res.stdout.splitlines():
        subdir = subdir.strip()
        if subdir == "":
            continue
        subdir_path = queue_dir + "/" + subdir
        sub_st = ctx.stat(subdir_path)
        if not sub_st or not sub_st.get("is_dir"):
            continue
        size_val = 0
        count_val = 0
        files_res = ctx.run(["ls", "-1A", subdir_path], mutates=False)
        if files_res.rc != 0:
            continue
        file_list = files_res.stdout.splitlines()
        count_val = len([f for f in file_list if f.strip() != ""])
        for fname in file_list:
            fname = fname.strip()
            if fname == "" or fname == "." or fname == "..":
                continue
            fpath = subdir_path + "/" + fname
            fst = ctx.stat(fpath)
            if fst and fst.get("exists"):
                size_val = size_val + fst.get("size", 0)

        if subdir == "deferred":
            deferred_size = deferred_size + size_val
            deferred_count = deferred_count + count_val
        elif subdir == "failed":
            failed_size = failed_size + size_val
            failed_count = failed_count + count_val

    p_def = params.get("deferred", (10, 20))
    p_fail = params.get("failed", (1, 1))
    def_w, def_c = p_def[0], p_def[1]
    fai_w, fai_c = p_fail[0], p_fail[1]

    metrics = {}
    metrics["deferred_length"] = deferred_count
    metrics["deferred_size"] = deferred_size
    metrics["failed_length"] = failed_count
    metrics["failed_size"] = failed_size

    def render_bytes(n):
        units = ["B", "KB", "MB", "GB", "TB"]
        i = 0
        v = float(n)
        while v >= 1024 and i < len(units) - 1:
            v = v / 1024.0
            i = i + 1
        s = "%d" % int(v) + " " + units[i] if i == 0 else "%f %s" % (v, units[i])
        return s

    def_level = "OK"
    if deferred_count >= def_c:
        def_level = "CRIT"
    elif deferred_count >= def_w:
        def_level = "WARN"

    fai_level = "OK"
    if failed_count >= fai_c:
        fai_level = "CRIT"
    elif failed_count >= fai_w:
        fai_level = "WARN"

    states = [def_level, fai_level]
    if "CRIT" in states:
        overall = "CRIT"
    elif "WARN" in states:
        overall = "WARN"
    else:
        overall = "OK"

    msg = "Deferred: %d mails (%s), Failed: %d mails (%s)" % (
        deferred_count, render_bytes(deferred_size),
        failed_count, render_bytes(failed_size))

    return {"changed": False, "msg": msg,
            "data": {"state": overall, "metrics": metrics, "details": msg}}