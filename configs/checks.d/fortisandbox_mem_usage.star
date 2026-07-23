def main(ctx, params):
    # Read meminfo
    content = ctx.file_read("/proc/meminfo")
    lines = content.split("\n")
    meminfo = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) >= 2:
            key = parts[0].rstrip(":")
            # Guard before parsing value — no try/except in Starlark
            if parts[1].isdigit():
                value = int(parts[1])
                meminfo[key] = value  # value is in kB

    # Discovery mode
    if params.get("_discover"):
        if "MemTotal" in meminfo:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {"levels": (80.0, 90.0)}, "metrics": ["mem_used_percent", "mem_lnx_total_used"]}]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    # Check mode for item "" (single-service check)
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Required values
    memtotal_kb = meminfo.get("MemTotal", 0)
    memfree_kb = meminfo.get("MemFree", 0)
    memavailable_kb = meminfo.get("MemAvailable", meminfo.get("MemFree", 0))
    swaptotal_kb = meminfo.get("SwapTotal", 0)
    swapfree_kb = meminfo.get("SwapFree", 0)
    pagetables_kb = meminfo.get("PageTables", 0)
    buffers_kb = meminfo.get("Buffers", 0)
    cached_kb = meminfo.get("Cached", 0)

    # Handle zero MemTotal
    if memtotal_kb == 0:
        return {
            "changed": False,
            "msg": "Reported total memory is 0 B, this may be caused by the lack of a memory cgroup in the kernel",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Compute memory usage
    memused_kb = memtotal_kb - memfree_kb
    caches_kb = buffers_kb + cached_kb
    ramused_kb = memused_kb - caches_kb
    ramused_bytes = int(ramused_kb * 1024)
    memtotal_bytes = int(memtotal_kb * 1024)

    # Percent used (RAM only, per Checkmk logic)
    memused_percent = 100.0 * ramused_bytes / memtotal_bytes

    # Swap metrics
    swapused_bytes = 0
    swaptotal_bytes = int(swaptotal_kb * 1024)
    if swaptotal_kb > 0:
        swapused_kb = swaptotal_kb - swapfree_kb
        swapused_bytes = int(swapused_kb * 1024)

    # Metrics map
    metrics = {
        "mem_used": ramused_bytes,
        "mem_used_percent": memused_percent,
        "mem_lnx_page_tables": int(pagetables_kb * 1024),
    }
    if swaptotal_kb > 0:
        metrics["swap_used"] = swapused_bytes

    # Total used: RAM + Swap + Pagetables (per Checkmk logic)
    totalused_kb = ramused_kb
    if swaptotal_kb > 0:
        totalused_kb += swapused_kb
    if pagetables_kb > 0:
        totalused_kb += pagetables_kb
    totalused_bytes = int(totalused_kb * 1024)

    # Levels
    warn_pct, crit_pct = params.get("levels", (80.0, 90.0))  # Checkmk default for fortisandbox
    warn_bytes = int(warn_pct / 100.0 * totalused_kb * 1024)  # warn_pct is percentage of total RAM+Swap+PageTables
    crit_bytes = int(crit_pct / 100.0 * totalused_kb * 1024)

    # Compute state
    if totalused_bytes >= crit_bytes:
        state = "CRIT"
    elif totalused_bytes >= warn_bytes:
        state = "WARN"
    else:
        state = "OK"

    # Build message
    if state != "OK":
        details_text = "RAM"
        if swaptotal_kb > 0:
            details_text += " + Swap"
        if pagetables_kb > 0:
            details_text += " + Pagetables"
        levels_text = "Warn/Crit: %d%%/%d%%" % (warn_pct, crit_pct)
        msg = "%s %d%% used (%s)" % (details_text, int(memused_percent), levels_text)
    else:
        msg = "RAM %d%% used" % int(memused_percent)

    # Additional metrics
    if "Mapped" in meminfo:
        mapped_kb = meminfo.get("Mapped", 0)
        metrics["mem_lnx_mapped"] = int(mapped_kb * 1024)
        metrics["mem_lnx_committed_as"] = int(meminfo.get("Committed_AS", 0) * 1024)
        metrics["mem_lnx_shmem"] = int(meminfo.get("Shmem", 0) * 1024)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
