def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["load1", "load5", "load15"]}]},
        }

    # Check mode for single-service check
    # Read /proc/loadavg which contains: load1 load5 load15 pid last_pid
    res = ctx.run(["cat", "/proc/loadavg"], mutates=False)
    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return {
            "changed": False,
            "msg": "could not read CPU load",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parts = lines[0].split()
    if len(parts) < 3:
        return {
            "changed": False,
            "msg": "could not parse CPU load values",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Guard before parsing floats - ensure parts are numeric
    def is_float(s):
        s = s.strip()
        if not s:
            return False
        # Handle optional sign and decimal point
        s = s.lstrip("+-")
        if not s:
            return False
        if "." in s:
            parts_float = s.split(".")
            if len(parts_float) != 2:
                return False
            return parts_float[0].isdigit() and (not parts_float[1] or parts_float[1].isdigit())
        return s.isdigit()
    
    if not (is_float(parts[0]) and is_float(parts[1]) and is_float(parts[2])):
        return {
            "changed": False,
            "msg": "could not parse CPU load values",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    load1 = float(parts[0])
    load5 = float(parts[1])
    load15 = float(parts[2])

    # Get thresholds from params (Checkmk defaults)
    levels1 = params.get("levels1", None)
    levels5 = params.get("levels5", None)
    levels15 = params.get("levels15", (5.0, 10.0))

    def check_levels(value, levels):
        if levels == None:
            return "OK"
        warn = levels[0]
        crit = levels[1]
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
        return "OK"

    state1 = check_levels(load1, levels1)
    state5 = check_levels(load5, levels5)
    state15 = check_levels(load15, levels15)

    # Determine overall state: CRIT > WARN > OK
    state = "OK"
    if state15 == "CRIT" or state5 == "CRIT" or state1 == "CRIT":
        state = "CRIT"
    elif state15 == "WARN" or state5 == "WARN" or state1 == "WARN":
        state = "WARN"

    msg_parts = []
    msg_parts.append("load1: %f" % load1)
    msg_parts.append("load5: %f" % load5)
    msg_parts.append("load15: %f" % load15)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"load1": load1, "load5": load5, "load15": load15},
            "details": "",
        },
    }
