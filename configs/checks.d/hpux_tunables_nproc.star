TUNABLE = "nproc"
TUNABLE_DESCR = "processes"
DEFAULT_WARN = 90.0
DEFAULT_CRIT = 96.0

def _parse_tunables(ctx):
    res = ctx.run(["kctune"], mutates=False, ok_codes=[0])
    parsed = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0].strip()
        val_str = parts[1].strip()
        if val_str.isdigit():
            parsed[name] = int(val_str)
    return parsed

def _parse_section(ctx):
    res = ctx.run(["kctune", "-v"], mutates=False, ok_codes=[0])
    parsed = {}
    key = ""
    usage = 0
    for line in res.stdout.splitlines():
        if ":" not in line:
            continue
        idx = line.find(":")
        field = line[:idx].strip()
        value = line[idx+1:].strip()
        if field == "Tunable" or field == "Parameter":
            key = value
        elif field == "Usage":
            if value.lstrip("-").isdigit():
                usage = int(value)
        elif field == "Setting":
            if value.lstrip("-").isdigit() and key != "":
                parsed[key] = (usage, int(value))
                key = ""
                usage = 0
    return parsed

def main(ctx, params):
    if params.get("_discover"):
        section = _parse_section(ctx)
        if TUNABLE not in section:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                    "metrics": [TUNABLE_DESCR],
                },
            ]},
        }

    section = _parse_section(ctx)

    if TUNABLE not in section:
        return {
            "changed": False,
            "msg": "tunable %s not found" % TUNABLE,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    usage, threshold = section[TUNABLE]

    if threshold == 0:
        return {
            "changed": False,
            "msg": "tunable %s has zero threshold" % TUNABLE,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    levels = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))
    warn = levels[0]
    crit = levels[1]

    perc = float(usage) / float(threshold) * 100.0

    if perc > crit:
        state = "CRIT"
    elif perc > warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "%f%% used (%d/%d %s)" % (perc, usage, threshold, TUNABLE_DESCR)
    if state != "OK":
        msg = msg + " (warn/crit at %f/%f)" % (warn, crit)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {TUNABLE_DESCR: usage},
            "details": "",
        },
    }