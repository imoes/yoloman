DEFAULT_LEVELS = (150.0, 200.0)

def _get_levels_mode_from_value(value):
    return "upper" if value > 100.0 else "lower"

def _normalize_levels(mode, warn, crit, total_mb, _perc_total=1024.0, render_unit=1024*1024):
    if mode == "upper":
        if warn <= 100.0:
            warn_mb = total_mb * warn / 100.0
        else:
            warn_mb = warn
        if crit <= 100.0:
            crit_mb = total_mb * crit / 100.0
        else:
            crit_mb = crit
    else:
        warn_mb = warn
        crit_mb = crit
    
    levels_text = "warn @ %f MB, crit @ %f MB" % (warn_mb, crit_mb)
    return warn_mb, crit_mb, levels_text

def _compute_state(value_mb, warn_mb, crit_mb):
    if crit_mb != None and value_mb >= crit_mb:
        return "CRIT"
    if warn_mb != None and value_mb >= warn_mb:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        has_stats = False
        cgroup_paths = [
            "/sys/fs/cgroup/memory/memory.usage_in_bytes",
            "/sys/fs/cgroup/memory.current",
        ]
        
        for path in cgroup_paths:
            if ctx.file_exists(path):
                content = ctx.file_read(path).strip()
                if content != "":
                    if content.isdigit():
                        if int(content) > 0:
                            has_stats = True
                            break
        
        if not has_stats:
            res = ctx.run(["cat", "/proc/meminfo"], mutates=False)
            if res.rc == 0:
                for line in res.stdout.splitlines():
                    if line.startswith("MemTotal:"):
                        parts = line.split()
                        if len(parts) >= 2:
                            if parts[1].isdigit():
                                has_stats = True
                                break
        
        if has_stats:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": DEFAULT_LEVELS}, "metrics": ["mem_used", "mem_used_percent"]}
                ]},
            }
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
    
    item = params.get("item", "")
    levels = params.get("levels", DEFAULT_LEVELS)
    
    memtotal_kb = 0.0
    memfree_kb = 0.0
    
    res = ctx.run(["cat", "/proc/meminfo"], mutates=False)
    if res.rc == 0:
        for line in res.stdout.splitlines():
            if line.startswith("MemTotal:"):
                parts = line.split()
                if len(parts) >= 2:
                    if parts[1].isdigit():
                        memtotal_kb = float(parts[1])
            elif line.startswith("MemFree:"):
                parts = line.split()
                if len(parts) >= 2:
                    if parts[1].isdigit():
                        memfree_kb = float(parts[1])
    
    if memtotal_kb == 0.0:
        for path in ["/sys/fs/cgroup/memory/memory.usage_in_bytes", "/sys/fs/cgroup/memory.current"]:
            if ctx.file_exists(path):
                content = ctx.file_read(path).strip()
                if content != "":
                    if content.isdigit():
                        memtotal_kb = float(content) / 1024.0
                        break
    
    if memtotal_kb <= 0:
        return {
            "changed": False,
            "msg": "Reported total memory is 0 B, this may be caused by the lack of a memory cgroup in the kernel",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    memused_kb = memtotal_kb - memfree_kb
    
    memused_bytes = int(memused_kb * 1024)
    memtotal_bytes = int(memtotal_kb * 1024)
    
    memused_percent = 100.0 * float(memused_bytes) / float(memtotal_bytes) if memtotal_bytes > 0 else 0.0
    
    warn_val, crit_val = levels if isinstance(levels, (list, tuple)) else (None, None)
    if warn_val == None or crit_val == None:
        warn_val, crit_val = DEFAULT_LEVELS
    
    mode = _get_levels_mode_from_value(warn_val)
    warn_mb, crit_mb, levels_text = _normalize_levels(mode, warn_val, crit_val, memtotal_kb / 1024.0)
    
    comp_mb = memused_kb / 1024.0
    state = _compute_state(comp_mb, warn_mb, crit_mb)
    
    summary = "Memory: %f MB" % (comp_mb)
    if state != "OK":
        summary = "%s (%s)" % (summary, levels_text)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "mem_used": memused_bytes,
                "mem_used_percent": memused_percent,
                "mem_lnx_total_used": memused_bytes,
            },
            "details": "",
        },
    }