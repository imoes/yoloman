def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/meminfo"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "host not supported", "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        meminfo = {}
        for line in lines:
            parts = line.split()
            if len(parts) >= 2:
                key = parts[0].rstrip(":")
                val = parts[1]
                if val.isdigit():
                    meminfo[key] = int(val)
        if "MemTotal" not in meminfo:
            return {"changed": False, "msg": "no memory info", "data": {"discovery": []}}
        metrics = ["mem_used", "mem_used_percent"]
        if "SwapFree" in meminfo:
            metrics.append("swap_used")
        if "PageTables" in meminfo:
            metrics.append("mem_lnx_page_tables")
        return {
            "changed": False,
            "msg": "discovered 1 memory item",
            "data": {
                "discovery": [
                    {"item": "", "params": {"levels": [150, 200]}, "metrics": metrics}
                ]
            },
        }

    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(["cat", "/proc/meminfo"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {
            "changed": False,
            "msg": "/proc/meminfo not readable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    lines = res.stdout.splitlines()
    meminfo = {}
    for line in lines:
        parts = line.split()
        if len(parts) >= 2:
            key = parts[0].rstrip(":")
            val = parts[1]
            if val.isdigit():
                meminfo[key] = int(val)

    if "MemTotal" not in meminfo:
        return {
            "changed": False,
            "msg": "no memory info",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    memtotal_kb = float(meminfo["MemTotal"])
    if memtotal_kb == 0:
        return {
            "changed": False,
            "msg": "Reported total memory is 0 B, this may be caused by the lack of a memory cgroup in the kernel",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    memfree_kb = float(meminfo.get("MemFree", 0))
    memused_kb = memtotal_kb - memfree_kb

    swapused_kb = 0.0
    swap_used_bytes = 0
    if "SwapFree" in meminfo:
        swaptotal_kb = float(meminfo["SwapTotal"])
        swapfree_kb = float(meminfo["SwapFree"])
        swapused_kb = swaptotal_kb - swapfree_kb
        swap_used_bytes = int(swapused_kb * 1024)

    pagetables_kb = 0.0
    pagetables_bytes = 0
    if "PageTables" in meminfo:
        pagetables_kb = float(meminfo["PageTables"])
        pagetables_bytes = int(pagetables_kb * 1024)

    memtotal_bytes = int(memtotal_kb * 1024)
    caches_kb = float(meminfo.get("Buffers", 0)) + float(meminfo.get("Cached", 0))
    ramused_kb = memused_kb - caches_kb
    ramused_bytes = int(ramused_kb * 1024)

    totalused_kb = ramused_kb
    if swap_used_bytes > 0:
        totalused_kb += swapused_kb
    if pagetables_bytes > 0:
        totalused_kb += pagetables_kb

    totalused_bytes = int(totalused_kb * 1024)
    totalused_mb = totalused_kb / 1024.0

    used_percent = (100.0 * totalused_bytes / memtotal_bytes) if memtotal_bytes > 0 else 0.0

    metrics_out = {
        "mem_used": ramused_bytes,
        "mem_used_percent": used_percent,
    }
    if swap_used_bytes > 0:
        metrics_out["swap_used"] = swap_used_bytes
    if pagetables_bytes > 0:
        metrics_out["mem_lnx_page_tables"] = pagetables_bytes

    descr = ["RAM"]
    if swap_used_bytes > 0:
        descr.append("Swap")
    if pagetables_bytes > 0:
        descr.append("Pagetables")
    summary_name = "RAM" if len(descr) == 1 else "Total (%s)" % " + ".join(descr)

    summary_str = summary_name + ": %f MB" % totalused_mb

    levels = params.get("levels", [150.0, 200.0])
    warn_mb = abs(float(levels[0]))
    crit_mb = abs(float(levels[1]))

    state = "OK"
    if totalused_mb >= crit_mb:
        state = "CRIT"
    elif totalused_mb >= warn_mb:
        state = "WARN"

    levels_text = "levels: %f/%f MB" % (warn_mb, crit_mb)
    if state != "OK":
        summary_str = summary_str + " (" + levels_text + ")"

    details = "Total used: %f MB (%f%% of RAM)" % (totalused_mb, used_percent)
    if swap_used_bytes > 0:
        details += "\nSwap used: %f MB" % (swapused_kb / 1024.0)
    if pagetables_bytes > 0:
        details += "\nPagetables: %f MB" % (pagetables_kb / 1024.0)

    return {
        "changed": False,
        "msg": summary_str,
        "data": {"state": state, "metrics": metrics_out, "details": details},
    }