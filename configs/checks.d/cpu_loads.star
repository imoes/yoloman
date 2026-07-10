def main(ctx, params):
    loadavg_path = "/proc/loadavg"
    if not ctx.file_exists(loadavg_path):
        return {
            "changed": False,
            "msg": "Cannot read CPU load: " + loadavg_path + " not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    content = ctx.file_read(loadavg_path)
    lines = content.split("\n")
    if len(lines) == 0 or len(lines[0].strip()) == 0:
        return {
            "changed": False,
            "msg": "Empty CPU load file",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parts = lines[0].strip().split()
    if len(parts) < 3:
        return {
            "changed": False,
            "msg": "Unexpected format in " + loadavg_path,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse loads; Starlark float() fails with fail() on invalid input
    load1 = float(parts[0])
    load5 = float(parts[1])
    load15 = float(parts[2])

    levels1 = params.get("levels1")
    levels5 = params.get("levels5")
    levels15 = params.get("levels15", (5.0, 10.0))

    def compute_state(value, levels):
        if levels == None:
            return "OK"
        if type(levels) == "list" and len(levels) == 2:
            warn, crit = levels[0], levels[1]
            if value >= crit:
                return "CRIT"
            if value >= warn:
                return "WARN"
        return "OK"

    state1 = compute_state(load1, levels1)
    state5 = compute_state(load5, levels5)
    state15 = compute_state(load15, levels15)

    state = "OK"
    if state15 == "CRIT" or state5 == "CRIT" or state1 == "CRIT":
        state = "CRIT"
    elif state15 == "WARN" or state5 == "WARN" or state1 == "WARN":
        state = "WARN"

    msg = "Load: %0.2f, %0.2f, %0.2f" % (load1, load5, load15)
    details = ""
    if levels1 != None:
        details += "1m: " + state1 + "; "
    if levels5 != None:
        details += "5m: " + state5 + "; "
    details += "15m: " + state15
    details = details.strip("; ")

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"load1": load1, "load5": load5, "load15": load15},
            "details": details,
        },
    }
