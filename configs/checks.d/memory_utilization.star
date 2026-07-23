# Memory utilization check (checkmk.memory_utilization) translated to Starlark
# Reads /proc/meminfo and computes memory utilization as a percentage

def _parse_meminfo(lines):
    """Parse /proc/meminfo lines into a dict of key -> value (in kB)."""
    meminfo = {}
    for line in lines:
        parts = line.split(":")
        if len(parts) != 2:
            continue
        key = parts[0].strip()
        value_str = parts[1].strip().split(" ")[0]  # strip "kB" suffix
        if value_str.isdigit():
            meminfo[key] = int(value_str)
    return meminfo

def _compute_utilization(meminfo):
    """Compute memory utilization percentage from /proc/meminfo data."""
    if not (meminfo.get("MemTotal") and meminfo.get("MemAvailable") != None):
        return None
    total = float(meminfo["MemTotal"])
    available = float(meminfo["MemAvailable"])
    used = total - available
    if total == 0.0:
        return None
    return (used / total) * 100.0

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"levels": ("fixed", (70.0, 80.0))}, "metrics": ["mem_used_percent"]}]}
        }

    # Check mode: read /proc/meminfo
    res = ctx.run(["cat", "/proc/meminfo"], mutates=False)
    lines = res.stdout.splitlines()
    meminfo = _parse_meminfo(lines)
    utilization = _compute_utilization(meminfo)

    if utilization == None:
        return {
            "changed": False,
            "msg": "unable to determine memory utilization",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract levels from params or use defaults
    levels = params.get("levels", ("fixed", (70.0, 80.0)))
    if type(levels) == "list" and len(levels) == 2 and levels[0] == "fixed":
        warn, crit = levels[1]
    else:
        warn = 70.0
        crit = 80.0

    # Determine state
    if utilization >= crit:
        state = "CRIT"
    elif utilization >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Memory: %f%%" % utilization,
        "data": {
            "state": state,
            "metrics": {"mem_used_percent": utilization},
            "details": ""
        },
    }