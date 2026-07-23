def _parse_tunables(ctx):
    res = ctx.run(["hpuxctl", "-v"], mutates=False)
    parsed = {}
    key = ""
    usage = 0
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Tunable:") or stripped.startswith("Parameter:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                key = parts[1].strip()
        elif stripped.startswith("Usage:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val.isdigit():
                    usage = int(val)
        elif stripped.startswith("Setting:") or stripped.startswith("Value:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val.isdigit():
                    threshold = int(val)
                    if key != "":
                        parsed[key] = (usage, threshold)
    return parsed

def main(ctx, params):
    if params.get("_discover"):
        section = _parse_tunables(ctx)
        if "nkthread" in section:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": [80.0, 85.0]},
                     "metrics": ["nkthread"]}
                ]}
            }
        return {
            "changed": False,
            "msg": "no nkthread tunable found",
            "data": {"discovery": []}
        }

    # check mode
    section = _parse_tunables(ctx)
    if "nkthread" not in section:
        return {
            "changed": False,
            "msg": "nkthread tunable not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    usage, threshold = section["nkthread"]
    if threshold == 0:
        return {
            "changed": False,
            "msg": "threshold is zero - cannot calculate percentage",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    warn, crit = params.get("levels", [80.0, 85.0])
    perc = float(usage) / float(threshold) * 100.0
    
    state = "OK"
    if perc > crit:
        state = "CRIT"
    elif perc > warn:
        state = "WARN"
    
    warn_perf = float(warn * threshold / 100.0)
    crit_perf = float(crit * threshold / 100.0)
    
    msg = "%f%% used (%d/%d threads)" % (perc, usage, threshold)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"nkthread": usage},
            "details": ""
        }
    }