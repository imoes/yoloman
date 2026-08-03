# Check plugin: checkmk.cpu_loads — CPU load (1/5/15-minute load averages)
# Translated to a read-only Starlark check module for the yolo-man agent.
# The original Checkmk plugin reads the "cpu" section, which the agent populates
# from /proc/loadavg (standard Linux load average source).

def _parse_loadavg(content):
    parts = content.split()
    # /proc/loadavg looks like: "0.01 0.05 0.08 1/234 12345"
    l1 = float(parts[0])
    l5 = float(parts[1])
    l15 = float(parts[2])
    return {"load1": l1, "load5": l5, "load15": l15}

def _grade(value, levels):
    # levels is (warn, crit); upper-level semantics (WARN/CRIT on >=)
    if levels == None or len(levels) < 2:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _best_state(s1, s5, s15):
    order = ["OK", "WARN", "CRIT", "UNKNOWN"]
    worst = "OK"
    for s in [s1, s5, s15]:
        if order.index(s) > order.index(worst):
            worst = s
    return worst

def main(ctx, params):
    if params.get("_discover"):
        if not ctx.file_exists("/proc/loadavg"):
            return {"changed": False, "msg": "not applicable", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "levels1": params.get("levels1", None),
                            "levels5": params.get("levels5", None),
                            "levels15": params.get("levels15", (5.0, 10.0)),
                        },
                        "metrics": ["load1", "load5", "load15"],
                    }
                ],
            },
        }

    if not ctx.file_exists("/proc/loadavg"):
        return {
            "changed": False,
            "msg": "no /proc/loadavg found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "load averages unavailable"},
        }

    loads = _parse_loadavg(ctx.file_read("/proc/loadavg"))
    levels1 = params.get("levels1", None)
    levels5 = params.get("levels5", None)
    levels15 = params.get("levels15", (5.0, 10.0))

    s1 = _grade(loads["load1"], levels1)
    s5 = _grade(loads["load5"], levels5)
    s15 = _grade(loads["load15"], levels15)
    state = _best_state(s1, s5, s15)

    details = "1min %f (%s) 5min %f (%s) 15min %f (%s)" % (
        loads["load1"], s1, loads["load5"], s5, loads["load15"], s15
    )

    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": {"load1": loads["load1"], "load5": loads["load5"], "load15": loads["load15"]},
            "details": details,
        },
    }