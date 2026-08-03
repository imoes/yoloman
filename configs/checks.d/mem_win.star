# checkmk.mem_win -> read-only Starlark check module (Windows memory)
# Single-service check. Probes Windows memory via the Checkmk mem section
# source on host: here translated to /proc/meminfo (mem_win is a Windows
# check; on a Linux host without Windows memory the data does not apply),
# so discovery is empty and check mode reports UNKNOWN. The check reproduces
# the static threshold logic for RAM and pagefile (Virtual memory).

def _levels_upper(levels):
    # levels_upper is ("fixed", (warn, crit)) in checkmk defaults
    if levels == None:
        return None
    if type(levels) != "dict":
        return None
    return levels.get("upper")

def _thresholds(state, value, levels, lower_is_worse):
    ul = _levels_upper(levels)
    if ul == None:
        return state
    if type(ul) != "list":
        return state
    # ul is ("fixed", (warn, crit))
    pair = ul[1]
    if type(pair) != "list" or len(pair) < 2:
        return state
    warn = pair[0]
    crit = pair[1]
    if value == None:
        return state
    s = "OK"
    if lower_is_worse:
        if value <= crit:
            s = "CRIT"
        elif value <= warn:
            s = "WARN"
    else:
        if value >= crit:
            s = "CRIT"
        elif value >= warn:
            s = "WARN"
    # notice_only: never demote an existing worse state
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if rank.get(s, 0) > rank.get(state, 0):
        return s
    return state

def main(ctx, params):
    if params.get("_discover"):
        # mem_win is a Windows-only check. Determine whether Windows memory
        # data is available on this host. On Linux there is no Windows mem
        # section, so this check does not apply -> empty discovery.
        meminfo = ctx.stat("/proc/meminfo")
        if meminfo != None and meminfo.get("is_dir") == False:
            # /proc/meminfo is present but this is a Linux host; Windows
            # memory section is not available.
            return {"changed": False, "msg": "discovered 0 items (Windows memory not present)",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 0 items (Windows memory not present)",
                "data": {"discovery": []}}

    item = params.get("item", "")

    # Windows memory parameters (Checkmk defaults from plugin)
    # memory perc_used upper = ("fixed", (80.0, 90.0)); pagefile same.
    mem_levels = params.get("memory", {})
    page_levels = params.get("pagefile", {})
    if mem_levels == None:
        mem_levels = {}
    if page_levels == None:
        page_levels = {}

    mem_perc = mem_levels.get("perc_used")
    mem_abs_free = mem_levels.get("abs_free")
    mem_abs_used = mem_levels.get("abs_used")
    page_perc = page_levels.get("perc_used")
    page_abs_free = page_levels.get("abs_free")
    page_abs_used = page_levels.get("abs_used")

    # Probe Windows memory via the on-host source the agent/section would
    # read. On a non-Windows host this is unavailable.
    meminfo = ctx.stat("/proc/meminfo")
    if meminfo == None or meminfo.get("exists") == False:
        return {"changed": False, "msg": "no Windows memory section found (not a Windows host)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read("/proc/meminfo") if ctx.file_exists("/proc/meminfo") else ""
    if content == "":
        return {"changed": False, "msg": "no Windows memory section found (not a Windows host)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse MemTotal/MemFree from /proc/meminfo. Note: mem_win is a Windows
    # check; on Linux we cannot produce genuine Windows memory numbers, so
    # report UNKNOWN. This honors "absence is an answer".
    total = None
    free = None
    for line in content.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            if parts[0] == "MemTotal:":
                total = int(parts[1]) if parts[1].isdigit() else None
            elif parts[0] == "MemFree:":
                free = int(parts[1]) if parts[1].isdigit() else None

    if total == None or free == None:
        return {"changed": False, "msg": "no Windows memory section found (not a Windows host)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # mem_win monitors Windows; /proc/meminfo is the Linux equivalent and
    # not the real source. Per the translation rules, do not substitute a
    # different data source for the product being monitored.
    return {"changed": False, "msg": "mem_win is a Windows-only check; no Windows memory source on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}