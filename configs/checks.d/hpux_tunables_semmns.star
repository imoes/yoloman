def _parse_tunables(ctx):
    res = ctx.run(["kctune", "-q", "semmns"], mutates=False)
    if res.rc != 0:
        return None
    tunables = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("Tunable"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            key = parts[0]
            val_str = parts[1]
            if val_str.isdigit():
                tunables[key] = int(val_str)
    return tunables


def _parse_kctune_all(ctx):
    res = ctx.run(["kctune"], mutates=False)
    if res.rc != 0:
        return {}
    parsed = {}
    key = ""
    usage = 0
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Tunable") or stripped.startswith("Parameter"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                key = parts[1].strip()
        elif stripped.startswith("Usage"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                usage = int(val) if val.isdigit() else 0
        elif stripped.startswith("Setting"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val.isdigit() and key != "":
                    parsed[key] = (usage, int(val))
    return parsed


def _get_semmns(ctx):
    res = ctx.run(["kctune", "semmns"], mutates=False)
    if res.rc != 0:
        return None, None
    usage = None
    setting = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Tunable") or stripped.startswith("Parameter"):
            pass
        elif stripped.startswith("Usage"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                usage = int(val) if val.isdigit() else 0
        elif stripped.startswith("Setting"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val.isdigit():
                    setting = int(val)
    return usage, setting


def main(ctx, params):
    if params.get("_discover"):
        usage, setting = _get_semmns(ctx)
        if usage == None or setting == None or setting == 0:
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
                    "params": {"levels": (85.0, 90.0)},
                    "metrics": ["entries"],
                },
            ]},
        }

    usage, setting = _get_semmns(ctx)
    if usage == None or setting == None:
        return {
            "changed": False,
            "msg": "semmns tunable not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if setting == 0:
        return {
            "changed": False,
            "msg": "semmns setting is zero",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    levels = params.get("levels", (85.0, 90.0))
    warn = float(levels[0])
    crit = float(levels[1])

    perc = float(usage) / float(setting) * 100.0

    if perc > crit:
        state = "CRIT"
    elif perc > warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "%f%% used (%d/%d entries)" % (perc, usage, setting)
    if state != "OK":
        msg = msg + " (warn/crit at %g/%g)" % (warn, crit)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"entries": usage},
            "details": "",
        },
    }