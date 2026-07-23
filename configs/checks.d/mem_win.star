def main(ctx, params):
    if params.get("_discover"):
        # Discovery: yield one service if both MemTotal and PageTotal are present
        # We'll probe the registry for memory info via wmic or Get-CimInstance
        # Using wmic (available on most Windows systems) to get memory info
        res = ctx.run(["wmic", "OS", "get", "TotalVisibleMemorySize,FreePhysicalMemory,TotalVirtualMemorySize,FreeVirtualMemory", "/value"], mutates=False)
        lines = res.stdout.splitlines()
        section = {}
        for line in lines:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip()
                if k == "TotalVisibleMemorySize":
                    section["MemTotal"] = int(v) * 1024  # Convert KB to bytes
                elif k == "FreePhysicalMemory":
                    section["MemFree"] = int(v) * 1024
                elif k == "TotalVirtualMemorySize":
                    section["PageTotal"] = int(v) * 1024
                elif k == "FreeVirtualMemory":
                    section["PageFree"] = int(v) * 1024

        if "MemTotal" in section and "PageTotal" in section:
            return {
                "changed": False,
                "msg": "discovered Memory service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["mem_used_percent", "pagefile_used_percent"]}]}
            }
        else:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }

    # Check mode (item is always "" for this single-service check)
    res = ctx.run(["wmic", "OS", "get", "TotalVisibleMemorySize,FreePhysicalMemory,TotalVirtualMemorySize,FreeVirtualMemory", "/value"], mutates=False)
    lines = res.stdout.splitlines()
    section = {}
    for line in lines:
        line = line.strip()
        if "=" in line:
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip()
            if k == "TotalVisibleMemorySize":
                section["MemTotal"] = int(v) * 1024
            elif k == "FreePhysicalMemory":
                section["MemFree"] = int(v) * 1024
            elif k == "TotalVirtualMemorySize":
                section["PageTotal"] = int(v) * 1024
            elif k == "FreeVirtualMemory":
                section["PageFree"] = int(v) * 1024

    # Validate required keys
    required_keys = ["MemTotal", "MemFree", "PageTotal", "PageFree"]
    missing = [k for k in required_keys if k not in section]
    if missing:
        return {
            "changed": False,
            "msg": "missing data for: " + ", ".join(missing),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract defaults from Checkmk defaults
    memory_params = params.get("memory", {})
    pagefile_params = params.get("pagefile", {})
    
    memory_levels = memory_params if memory_params else {
        "perc_used": {
            "lower": ("no_levels", None),
            "upper": ("fixed", (80.0, 90.0))
        }
    }
    pagefile_levels = pagefile_params if pagefile_params else {
        "perc_used": {
            "lower": ("no_levels", None),
            "upper": ("fixed", (80.0, 90.0))
        }
    }

    result_parts = []
    metrics = {}
    overall_state = "OK"

    # Process RAM
    mem_total = section["MemTotal"]
    mem_free = section["MemFree"]
    mem_used = mem_total - mem_free
    mem_used_percent = (mem_used / mem_total) * 100.0 if mem_total > 0 else 0.0
    
    # Process levels for RAM
    mem_levels = memory_levels.get("perc_used", {})
    mem_upper = mem_levels.get("upper")
    mem_lower = mem_levels.get("lower")
    
    # Determine state for RAM
    if mem_upper and mem_upper[0] == "fixed":
        upper_val = mem_upper[1]
        if mem_used_percent >= upper_val[1]:
            mem_state = "CRIT"
        elif mem_used_percent >= upper_val[0]:
            mem_state = "WARN"
        else:
            mem_state = "OK"
    elif mem_lower and mem_lower[0] == "fixed":
        lower_val = mem_lower[1]
        if mem_used_percent <= lower_val[0]:
            mem_state = "CRIT"
        elif mem_used_percent <= lower_val[1]:
            mem_state = "WARN"
        else:
            mem_state = "OK"
    else:
        mem_state = "OK"
    
    # Update overall state
    if mem_state == "CRIT" or overall_state == "CRIT":
        overall_state = "CRIT"
    elif mem_state == "WARN" or overall_state == "WARN":
        overall_state = "WARN"
    
    result_parts.append("RAM: %f%% used" % mem_used_percent)
    metrics["mem_used_percent"] = mem_used_percent
    metrics["mem_used"] = mem_used
    metrics["mem_free"] = mem_free

    # Process Pagefile
    page_total = section["PageTotal"]
    page_free = section["PageFree"]
    page_used = page_total - page_free
    page_used_percent = (page_used / page_total) * 100.0 if page_total > 0 else 0.0
    
    # Process levels for pagefile
    pf_levels = pagefile_levels.get("perc_used", {})
    pf_upper = pf_levels.get("upper")
    pf_lower = pf_levels.get("lower")
    
    # Determine state for Pagefile
    if pf_upper and pf_upper[0] == "fixed":
        upper_val = pf_upper[1]
        if page_used_percent >= upper_val[1]:
            pf_state = "CRIT"
        elif page_used_percent >= upper_val[0]:
            pf_state = "WARN"
        else:
            pf_state = "OK"
    elif pf_lower and pf_lower[0] == "fixed":
        lower_val = pf_lower[1]
        if page_used_percent <= lower_val[0]:
            pf_state = "CRIT"
        elif page_used_percent <= lower_val[1]:
            pf_state = "WARN"
        else:
            pf_state = "OK"
    else:
        pf_state = "OK"
    
    # Update overall state
    if pf_state == "CRIT" or overall_state == "CRIT":
        overall_state = "CRIT"
    elif pf_state == "WARN" or overall_state == "WARN":
        overall_state = "WARN"
    
    result_parts.append("Pagefile: %f%% used" % page_used_percent)
    metrics["pagefile_used_percent"] = page_used_percent
    metrics["pagefile_used"] = page_used
    metrics["pagefile_free"] = page_free

    return {
        "changed": False,
        "msg": ", ".join(result_parts),
        "data": {
            "state": overall_state,
            "metrics": metrics,
            "details": ""
        }
    }