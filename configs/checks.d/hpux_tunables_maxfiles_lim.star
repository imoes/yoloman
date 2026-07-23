TUNABLE = "maxfiles_lim"
DESCR = "files"
DEFAULT_WARN = 85.0
DEFAULT_CRIT = 90.0

def _parse_tunables(stdout):
    parsed = {}
    key = ""
    usage = 0
    for line in stdout.splitlines():
        if ":" not in line:
            continue
        parts = line.split(":", 1)
        label = parts[0].strip()
        value = parts[1].strip() if len(parts) > 1 else ""
        if label == "Tunable" or label == "Parameter":
            key = value
        elif label == "Usage":
            usage = int(value) if value.isdigit() else 0
        elif label == "Setting":
            threshold = int(value) if value.isdigit() else 0
            if key != "":
                parsed[key] = (usage, threshold)
    return parsed

def main(ctx, params):
    res = ctx.run(["cat", "/proc/hpux_tunables"], mutates=False, ok_codes=[0, 1, 2])
    if res.rc != 0 or not res.stdout:
        res2 = ctx.run(["kctune"], mutates=False, ok_codes=[0, 1, 2])
        raw = res2.stdout if res2.rc == 0 else ""
    else:
        raw = res.stdout

    if not raw:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "hpux_tunables data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parsed = _parse_tunables(raw)

    if params.get("_discover"):
        if TUNABLE in parsed:
            return {
                "changed": False,
                "msg": "discovered 1 items",
                "data": {"discovery": [
                    {
                        "item": "",
                        "params": {"levels": [DEFAULT_WARN, DEFAULT_CRIT]},
                        "metrics": [DESCR],
                    }
                ]},
            }
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

    if TUNABLE not in parsed:
        return {
            "changed": False,
            "msg": TUNABLE + " not found in tunables output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    usage, threshold = parsed[TUNABLE]
    if threshold == 0:
        return {
            "changed": False,
            "msg": "threshold is zero, cannot compute percentage",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    levels = params.get("levels", [DEFAULT_WARN, DEFAULT_CRIT])
    warn = float(levels[0])
    crit = float(levels[1])

    perc = float(usage) / float(threshold) * 100.0

    if perc > crit:
        state = "CRIT"
    elif perc > warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "%f%% used (%d/%d %s)" % (perc, usage, threshold, DESCR)
    if state != "OK":
        msg = msg + " (warn/crit at %f/%f)" % (warn, crit)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {DESCR: usage},
            "details": "",
        },
    }