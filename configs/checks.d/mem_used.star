def main(ctx, params):
    # Discovery mode: yield a single service if MemTotal exists
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/meminfo"], mutates=False)
        meminfo = {}
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                key = parts[0].rstrip(":")
                value_str = parts[1]
                if value_str.isdigit():
                    meminfo[key] = int(value_str) * 1024  # convert kB to bytes
                else:
                    meminfo[key] = 0
        if "MemTotal" in meminfo:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {
                                "levels": [150.0, 200.0],
                                "average": None
                            },
                            "metrics": ["mem_used", "mem_used_percent", "mem_lnx_total_used", "swap_used", "mem_lnx_page_tables"]
                        }
                    ]
                },
            }
        else:
            return {
                "changed": False,
                "msg": "no MemTotal found",
                "data": {"discovery": []}
            }

    # Check mode for single item (item is always "" for this check)
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/meminfo"], mutates=False)
    meminfo = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            key = parts[0].rstrip(":")
            value_str = parts[1]
            if value_str.isdigit():
                meminfo[key] = int(value_str) * 1024  # kB to bytes
            else:
                meminfo[key] = 0

    # Check required keys exist
    if "MemTotal" not in meminfo:
        return {
            "changed": False,
            "msg": "Reported total memory is 0 B, this may be caused by the lack of a memory cgroup in the kernel",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    memtotal_kb = meminfo.get("MemTotal", 0) / 1024.0
    memtotal_bytes = meminfo.get("MemTotal", 0)
    memfree_kb = meminfo.get("MemFree", 0) / 1024.0
    memused_kb = memtotal_kb - memfree_kb

    # Caches (Buffers + Cached) in bytes
    buffers_kb = meminfo.get("Buffers", 0) / 1024.0
    cached_kb = meminfo.get("Cached", 0) / 1024.0
    caches_kb = buffers_kb + cached_kb
    ramused_kb = memused_kb - caches_kb

    # Swap info
    swaptotal_bytes = meminfo.get("SwapTotal", 0)
    swapfree_bytes = meminfo.get("SwapFree", 0)
    swapused_kb = (swaptotal_bytes - swapfree_bytes) / 1024.0 if swaptotal_bytes > 0 else 0.0

    # Pagetables
    pagetables_kb = meminfo.get("PageTables", 0) / 1024.0

    # Calculate total used
    totalused_kb = ramused_kb + swapused_kb + pagetables_kb

    # Levels from params (Checkmk defaults: (150.0, 200.0) in MB)
    levels = params.get("levels", [150.0, 200.0])
    warn_mb = float(levels[0]) if len(levels) > 0 else 150.0
    crit_mb = float(levels[1]) if len(levels) > 1 else 200.0

    # Convert to bytes for comparison
    warn_bytes = warn_mb * 1024 * 1024
    crit_bytes = crit_mb * 1024 * 1024
    totalused_bytes = int(totalused_kb * 1024)

    # Compute state: upper levels (WARN if >= warn, CRIT if >= crit)
    if totalused_bytes >= crit_bytes:
        state = "CRIT"
    elif totalused_bytes >= warn_bytes:
        state = "WARN"
    else:
        state = "OK"

    # Build details message
    details_parts = ["RAM"]
    if swapused_kb > 0:
        details_parts.append("Swap")
    if pagetables_kb > 0:
        details_parts.append("Pagetables")
    
    if len(details_parts) == 1:
        totalused_desc = "RAM"
    else:
        totalused_desc = "Total (%s)" % " + ".join(details_parts)

    # Render sizes
    def format_bytes(b):
        if b >= 1024 * 1024 * 1024:
            return "%f GB" % (b / (1024 * 1024 * 1024))
        elif b >= 1024 * 1024:
            return "%f MB" % (b / (1024 * 1024))
        elif b >= 1024:
            return "%f kB" % (b / 1024)
        else:
            return "%d B" % b

    # Build summary
    infotext = "%s: %s" % (totalused_desc, format_bytes(totalused_bytes))

    # Levels text (only add if non-default)
    levels_text = ""
    if (warn_mb != 150.0 or crit_mb != 200.0) and state != "OK":
        levels_text = "warn/crit at %f MB/%f MB" % (warn_mb, crit_mb)

    if levels_text:
        infotext = "%s (%s)" % (infotext, levels_text)

    # Average support (optional)
    average_min = params.get("average")
    if average_min and type(average_min) == "int":
        # No real averaging possible in this simple check,
        # but we can simulate the message format
        infotext = "%s, %d min average %f%%" % (
            infotext,
            average_min,
            (totalused_kb / (memtotal_kb + swapused_kb * 1024.0 + pagetables_kb * 1024.0) * 100)
        )

    # Metrics dict (all in bytes, as numbers)
    mem_used_percent = 100.0 * ramused_kb / memtotal_kb if memtotal_kb > 0 else 0.0
    mem_used_percent_rounded = int(mem_used_percent * 10 + 0.5) / 10.0
    metrics = {
        "mem_used": int(ramused_kb * 1024),
        "mem_used_percent": mem_used_percent_rounded,
        "mem_lnx_total_used": totalused_bytes,
        "swap_used": int(swapused_kb * 1024),
        "mem_lnx_page_tables": int(pagetables_kb * 1024)
    }

    # Add additional Linux metrics if present
    if "Mapped" in meminfo:
        metrics["mem_lnx_mapped"] = meminfo["Mapped"]
    if "Committed_AS" in meminfo:
        metrics["mem_lnx_committed_as"] = meminfo["Committed_AS"]
    if "Shmem" in meminfo:
        metrics["mem_lnx_shmem"] = meminfo["Shmem"]

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }