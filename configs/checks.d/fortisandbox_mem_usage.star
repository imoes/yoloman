def main(ctx, params):
    if params.get("_discover"):
        res = ctx.file_read("/proc/meminfo")
        if res == "" or res == None:
            return {"changed": False, "msg": "no /proc/meminfo", "data": {"discovery": []}}
        
        has_memtotal = False
        for line in res.split("\n"):
            if line.startswith("MemTotal:"):
                has_memtotal = True
                break
        
        if not has_memtotal:
            return {"changed": False, "msg": "no MemTotal found", "data": {"discovery": []}}
        
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": (80.0, 90.0)},
                        "metrics": ["mem_used", "mem_used_percent", "swap_used", "mem_lnx_page_tables", "mem_lnx_total_used"],
                    },
                ],
            },
        }
    
    item = params.get("item", "")
    
    res = ctx.file_read("/proc/meminfo")
    if res == "" or res == None:
        return {
            "changed": False,
            "msg": "no /proc/meminfo available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    meminfo = {}
    for line in res.split("\n"):
        parts = line.split(":")
        if len(parts) >= 2:
            key = parts[0].strip()
            rest = parts[1].strip()
            values = rest.split()
            if len(values) >= 1:
                meminfo[key] = int(values[0])
    
    memtotal_kb = meminfo.get("MemTotal", 0)
    memfree_kb = meminfo.get("MemFree", 0)
    
    if memtotal_kb == 0:
        return {
            "changed": False,
            "msg": "Reported total memory is 0 B, this may be caused by the lack of a memory cgroup in the kernel",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    memused_kb = memtotal_kb - memfree_kb
    swaptotal_kb = meminfo.get("SwapTotal", 0)
    swapfree_kb = meminfo.get("SwapFree", 0)
    swapused_kb = 0
    if swaptotal_kb > 0:
        swapused_kb = swaptotal_kb - swapfree_kb
    pagetables_kb = meminfo.get("PageTables", 0)
    buffers_kb = meminfo.get("Buffers", 0)
    cached_kb = meminfo.get("Cached", 0)
    
    caches_kb = buffers_kb + cached_kb
    ramused_kb = memused_kb - caches_kb
    
    memtotal_bytes = memtotal_kb * 1024
    memused_bytes = ramused_kb * 1024
    swapused_bytes = swapused_kb * 1024
    swap_total_bytes = swaptotal_kb * 1024
    pagetables_bytes = pagetables_kb * 1024
    
    ramused_mb = ramused_kb / 1024.0
    memtotal_mb = memtotal_kb / 1024.0
    
    memused_percent = (ramused_kb / memtotal_kb * 100.0) if memtotal_kb > 0 else 0.0
    
    levels = params.get("levels", (80.0, 90.0))
    if type(levels) == "list":
        levels = (levels[0], levels[1])
    warn_pct = levels[0]
    crit_pct = levels[1]
    
    totalvirt_kb = swaptotal_kb + memtotal_kb
    totalvirt_mb = totalvirt_kb / 1024.0
    
    warn_mb = totalvirt_mb * warn_pct / 100.0
    crit_mb = totalvirt_mb * crit_pct / 100.0
    
    comp_mb = ramused_mb + (swapused_kb / 1024.0) + (pagetables_kb / 1024.0)
    
    if comp_mb <= warn_mb:
        state = "OK"
    elif comp_mb <= crit_mb:
        state = "WARN"
    else:
        state = "CRIT"
    
    avg_min = params.get("average")
    
    details_parts = []
    details_parts.append("RAM: %d kB used of %d kB" % (ramused_kb, memtotal_kb))
    if swaptotal_kb > 0:
        details_parts.append("Swap: %d kB used of %d kB" % (swapused_kb, swaptotal_kb))
    if pagetables_kb > 0:
        details_parts.append("Pagetables: %d kB" % pagetables_kb)
    if buffers_kb > 0:
        details_parts.append("Buffers: %d kB" % buffers_kb)
    if cached_kb > 0:
        details_parts.append("Cached: %d kB" % cached_kb)
    
    if avg_min:
        details_parts.append("Average over %d min applied" % avg_min)
    
    levels_text = "levels at %f%%/%f%% of %d kB" % (warn_pct, crit_pct, totalvirt_kb)
    if state != "OK":
        details_parts.append(levels_text)
    
    msg = "%d kB used (%f%%)" % (comp_mb * 1024.0, comp_mb / memtotal_mb * 100.0) if memtotal_mb > 0 else "%d kB used" % (comp_mb * 1024.0)
    
    metrics = {
        "mem_used": memused_bytes,
        "mem_used_percent": memused_percent,
        "swap_used": swapused_bytes,
        "mem_lnx_page_tables": pagetables_bytes,
        "mem_lnx_total_used": memused_bytes,
    }
    
    if meminfo.get("Mapped"):
        metrics["mem_lnx_mapped"] = meminfo.get("Mapped", 0) * 1024
    if meminfo.get("Committed_AS"):
        metrics["mem_lnx_committed_as"] = meminfo.get("Committed_AS", 0) * 1024
    if meminfo.get("Shmem"):
        metrics["mem_lnx_shmem"] = meminfo.get("Shmem", 0) * 1024
    
    detail = ", ".join(details_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": detail,
        },
    }