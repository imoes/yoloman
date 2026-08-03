def main(ctx, params):
    # ---- read current thread state from the real on-host source ----
    # The Checkmk cpu agent plugin reads /proc/cpuinfo for info and /proc/stat
    # for limits. The thread count we report here is the actual count of
    # schedulable threads on the host (matches "processes" in /proc/loadavg
    # which is what the agent-based lib uses for the "max" limit).
    loadavg = ctx.file_read("/proc/loadavg") if ctx.file_exists("/proc/loadavg") else ""
    threads_count = None
    threads_max = None
    if loadavg != "":
        parts = loadavg.split()
        # /proc/loadavg: ... <running> <total_running> <last_pid>
        # The 4th field is the kernel scheduling-thread count ("nr_threads").
        if len(parts) >= 4 and parts[3].isdigit():
            threads_count = int(parts[3])
    # Threads max: Checkmk's cpu section "max" is the configured max thread
    # limit. We take the kernel max from /proc/sys/kernel/threads-max.
    threads_max_path = "/proc/sys/kernel/threads-max"
    if ctx.file_exists(threads_max_path):
        raw = ctx.file_read(threads_max_path).strip()
        if raw.isdigit():
            threads_max = int(raw)

    # ---- discovery mode ----
    if params.get("_discover"):
        # The Checkmk discover function yields a Service only when there are
        # threads reported by the section. Here threads come from the real
        # host source, so absence means nothing to discover.
        if threads_count == None and threads_max == None:
            return {
                "changed": False,
                "msg": "no thread data available on this host",
                "data": {"discovery": []},
            }
        discovery = [
            {
                "item": "",
                "params": {"levels": (2000, 4000)},
                "metrics": ["threads", "thread_usage"],
            }
        ]
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": discovery},
        }

    # ---- check mode ----
    # A single-service check uses item "".
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if threads_count == None and threads_max == None:
        return {
            "changed": False,
            "msg": "no thread data available on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    details_lines = []
    state = "OK"

    # levels_upper: warn if value >= warn, crit if value >= crit
    def grade_upper(value, warn, crit):
        if crit != None and value >= crit:
            return "CRIT"
        if warn != None and value >= warn:
            return "WARN"
        return "OK"

    if threads_count != None:
        metrics["threads"] = threads_count
        details_lines.append("Threads count: %d" % threads_count)
        # params may come as {"levels": "no_levels"} or a tuple/list
        raw_levels = params.get("levels")
        warn = None
        crit = None
        if type(raw_levels) == "list" and len(raw_levels) == 2:
            warn = raw_levels[0]
            crit = raw_levels[1]
        elif type(raw_levels) == "tuple" and len(raw_levels) == 2:
            warn = raw_levels[0]
            crit = raw_levels[1]
        if warn != None or crit != None:
            st = grade_upper(threads_count, warn, crit)
            if st == "CRIT":
                state = "CRIT"
            elif st == "WARN" and state != "CRIT":
                state = "WARN"

    if threads_max != None and threads_count != None:
        thread_usage = 100.0 * threads_count / threads_max
        metrics["thread_usage"] = thread_usage
        details_lines.append(
            "Threads usage: %s%% (%d of %d)" % ("{:.2f}".format(thread_usage), threads_count, threads_max)
        )
        raw_levels_pct = params.get("levels_percent")
        warn = None
        crit = None
        if type(raw_levels_pct) == "list" and len(raw_levels_pct) == 2:
            warn = raw_levels_pct[0]
            crit = raw_levels_pct[1]
        elif type(raw_levels_pct) == "tuple" and len(raw_levels_pct) == 2:
            warn = raw_levels_pct[0]
            crit = raw_levels_pct[1]
        if warn != None or crit != None:
            st = grade_upper(thread_usage, warn, crit)
            if st == "CRIT":
                state = "CRIT"
            elif st == "WARN" and state != "CRIT":
                state = "WARN"

    msg = "; ".join(details_lines) if details_lines else "Number of threads"
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": "\n".join(details_lines)},
    }