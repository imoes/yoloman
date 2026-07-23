def _safe_float(s):
    s = s.strip()
    if not s:
        return 0.0
    neg = s.startswith("-")
    core = s[1:] if neg else s
    if core.count(".") > 1:
        return 0.0
    nodot = core.replace(".", "")
    if nodot == "" or not nodot.isdigit():
        return 0.0
    return float(s)

def _safe_int(s):
    s = s.strip()
    if s.isdigit():
        return int(s)
    return 0

def _parse_ps_line(line):
    parts = line.split(None, 6)
    if len(parts) < 6:
        return None
    return {
        "pid":  parts[0],
        "user": parts[1],
        "pcpu": parts[2],
        "rss":  parts[3],
        "vsz":  parts[4],
        "comm": parts[5],
        "args": parts[6] if len(parts) > 6 else parts[5],
    }

def _proc_matches(proc, pattern, user_filter):
    if user_filter != None and proc["user"] != user_filter:
        return False
    if pattern == None or pattern == "":
        return True
    return proc["comm"].find(pattern) >= 0 or proc["args"].find(pattern) >= 0

def _worse(s1, s2):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(s2, 0) > order.get(s1, 0):
        return s2
    return s1

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["ps", "-eo", "comm", "--no-headers"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "ps failed", "data": {"discovery": []}}
        seen = {}
        for line in res.stdout.splitlines():
            comm = line.strip()
            if not comm or comm == "COMMAND" or comm == "COMM":
                continue
            seen[comm] = True
        items = [
            {
                "item": comm,
                "params": {
                    "process": comm,
                    "levels": [1, 1, 99999, 99999],
                    "cpu_rescale_max": False,
                },
                "metrics": ["count", "pcpu", "rss", "vsz"],
            }
            for comm in sorted(seen.keys())
        ]
        return {
            "changed": False,
            "msg": "discovered %d process groups" % len(items),
            "data": {"discovery": items},
        }

    item           = params.get("item", "")
    process        = params.get("process", item)
    user_filter    = params.get("user", None)
    levels         = params.get("levels", [1, 1, 99999, 99999])
    cpu_levels     = params.get("cpu", None)
    res_levels     = params.get("resident_levels", None)
    vsz_levels     = params.get("virtual_levels", None)

    count_warn_min = levels[0] if len(levels) > 0 else 1
    count_crit_min = levels[1] if len(levels) > 1 else 1
    count_warn_max = levels[2] if len(levels) > 2 else 99999
    count_crit_max = levels[3] if len(levels) > 3 else 99999

    res = ctx.run(
        ["ps", "-eo", "pid,user,pcpu,rss,vsz,comm,args", "--no-headers"],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "ps failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    count     = 0
    total_cpu = 0.0
    total_rss = 0   # KB
    total_vsz = 0   # KB

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("PID"):
            continue
        proc = _parse_ps_line(line)
        if proc == None:
            continue
        if _proc_matches(proc, process, user_filter):
            count     += 1
            total_cpu += _safe_float(proc["pcpu"])
            total_rss += _safe_int(proc["rss"])
            total_vsz += _safe_int(proc["vsz"])

    total_rss_bytes = total_rss * 1024
    total_vsz_bytes = total_vsz * 1024

    state  = "OK"
    issues = []

    # --- count thresholds ---
    if count < count_crit_min or count > count_crit_max:
        state = "CRIT"
        if count < count_crit_min:
            issues.append("%d process(es) < %d (crit min)" % (count, count_crit_min))
        else:
            issues.append("%d process(es) > %d (crit max)" % (count, count_crit_max))
    elif count < count_warn_min or count > count_warn_max:
        state = "WARN"
        if count < count_warn_min:
            issues.append("%d process(es) < %d (warn min)" % (count, count_warn_min))
        else:
            issues.append("%d process(es) > %d (warn max)" % (count, count_warn_max))

    # --- CPU thresholds ---
    if cpu_levels != None and count > 0:
        cpu_warn = cpu_levels[0] if len(cpu_levels) > 0 else None
        cpu_crit = cpu_levels[1] if len(cpu_levels) > 1 else None
        if cpu_crit != None and total_cpu >= cpu_crit:
            state = _worse(state, "CRIT")
            issues.append("CPU %f%% >= %f%% (crit)" % (total_cpu, cpu_crit))
        elif cpu_warn != None and total_cpu >= cpu_warn:
            state = _worse(state, "WARN")
            issues.append("CPU %f%% >= %f%% (warn)" % (total_cpu, cpu_warn))

    # --- resident (RSS) thresholds (bytes) ---
    if res_levels != None and count > 0:
        rss_warn = res_levels[0] if len(res_levels) > 0 else None
        rss_crit = res_levels[1] if len(res_levels) > 1 else None
        if rss_crit != None and total_rss_bytes >= rss_crit:
            state = _worse(state, "CRIT")
            issues.append("RSS %d MB >= %d MB (crit)" % (total_rss // 1024, rss_crit // 1024 // 1024))
        elif rss_warn != None and total_rss_bytes >= rss_warn:
            state = _worse(state, "WARN")
            issues.append("RSS %d MB >= %d MB (warn)" % (total_rss // 1024, rss_warn // 1024 // 1024))

    # --- virtual (VSZ) thresholds (bytes) ---
    if vsz_levels != None and count > 0:
        vsz_warn = vsz_levels[0] if len(vsz_levels) > 0 else None
        vsz_crit = vsz_levels[1] if len(vsz_levels) > 1 else None
        if vsz_crit != None and total_vsz_bytes >= vsz_crit:
            state = _worse(state, "CRIT")
            issues.append("VSZ %d MB >= %d MB (crit)" % (total_vsz // 1024, vsz_crit // 1024 // 1024))
        elif vsz_warn != None and total_vsz_bytes >= vsz_warn:
            state = _worse(state, "WARN")
            issues.append("VSZ %d MB >= %d MB (warn)" % (total_vsz // 1024, vsz_warn // 1024 // 1024))

    if count > 0:
        msg = "Processes %s: %d, CPU: %f%%, RSS: %d MB" % (
            item, count, total_cpu, total_rss // 1024)
    else:
        msg = "Processes %s: 0" % item

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "count":  count,
                "pcpu":   total_cpu,
                "rss":    total_rss_bytes,
                "vsz":    total_vsz_bytes,
            },
            "details": "\n".join(issues),
        },
    }