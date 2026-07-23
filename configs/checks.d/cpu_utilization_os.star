# ===== Starlark check module: cpu_utilization_os =====
# Translate Checkmk check: cpu_utilization_os (agent-based CPU utilization)

# Module-level constants for metric keys
UTIL_KEY = "util"

def main(ctx, params):
    if params.get("_discover"):
        # Single-service check: always discover one item with empty name
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["cpu_util"]}]},
        }

    # --- CHECK MODE (non-discovery) ---
    # Gather CPU time data from /proc/stat
    res = ctx.run(["cat", "/proc/stat"], mutates=False)
    lines = res.stdout.splitlines()
    cpu_line = ""
    for line in lines:
        if line.startswith("cpu "):
            cpu_line = line
            break

    if not cpu_line:
        return {
            "changed": False,
            "msg": "failed to read CPU stats from /proc/stat",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse cpu line fields: cpu user nice system idle iowait irq softirq steal guest guest_nice
    fields = cpu_line.split()
    if len(fields) < 5:
        return {
            "changed": False,
            "msg": "malformed /proc/stat cpu line",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Guard before parsing floats (no try/except in Starlark)
    # Validate fields are numeric before converting
    valid = True
    for i in range(1, min(len(fields), 6)):
        if not fields[i].replace('.','').replace('e','').replace('-','').isdigit() == False and fields[i] != "":
            # Basic numeric check: ensure it looks like a number
            parts = fields[i].split('.')
            if len(parts) > 2:
                valid = False
            else:
                for part in parts:
                    if part == "":
                        valid = False
                        break
                    for c in part:
                        if c not in "0123456789":
                            valid = False
                            break
                    if not valid:
                        break
        else:
            # If it contains non-digit characters, try basic validation
            if fields[i].replace('.','').replace('-','').replace('+','').replace('e','').replace('E','') == "":
                valid = False

    if not valid:
        return {
            "changed": False,
            "msg": "invalid numeric data in /proc/stat",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse values (safe due to validation above)
    user = float(fields[1])
    nice = float(fields[2])
    system = float(fields[3])
    idle = float(fields[4])
    iowait = float(fields[5]) if len(fields) > 5 else 0.0

    # Compute time_base (current timestamp in seconds since epoch)
    # Use /proc/uptime for timestamp
    uptime_res = ctx.run(["cat", "/proc/uptime"])
    uptime_fields = uptime_res.stdout.split()
    time_base = float(uptime_fields[0]) if uptime_fields else 0.0

    # Compute total CPU time and active (non-idle) time
    total = user + nice + system + idle + iowait
    if total == 0.0:
        util = 0.0
    else:
        active = user + nice + system + iowait
        util = active / total * 100.0

    # Retrieve thresholds (Checkmk defaults)
    warn_val = 80.0
    crit_val = 90.0

    # Handle levels parameter (Checkmk style: (warn, crit) tuple)
    levels = params.get("levels")
    if levels != None:
        if type(levels) == "list" or type(levels) == "tuple":
            if len(levels) >= 2:
                warn_val = float(levels[0])
                crit_val = float(levels[1])
            elif len(levels) == 1:
                warn_val = float(levels[0])
                crit_val = float(levels[0]) * 1.125  # typical Checkmk default ratio

    # Alternative: explicit warn/crit params
    if params.get("warn") != None:
        warn_val = float(params.get("warn"))
    if params.get("crit") != None:
        crit_val = float(params.get("crit"))

    # State determination (upper levels)
    state = "CRIT" if util >= crit_val else ("WARN" if util >= warn_val else "OK")

    return {
        "changed": False,
        "msg": "CPU utilization: %f%%" % util,
        "data": {
            "state": state,
            "metrics": {"cpu_util": util},
            "details": "",
        },
    }
