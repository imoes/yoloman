def _levels_upper(levels):
    if not levels:
        return None
    return levels.get("upper")

def _check_levels(value, metric_name, label, levels, render_func=None):
    if value == None:
        return {"state": "UNKNOWN", "metrics": {}, "details": "", "msg": label + ": no data"}
    v = float(value) if _is_number(value) else None
    if v == None:
        return {"state": "UNKNOWN", "metrics": {}, "details": "", "msg": label + ": cannot parse value"}
    metrics = {metric_name: v}
    upper = _levels_upper(levels)
    state = "OK"
    if upper != None:
        warn, crit = upper[0], upper[1]
        if v >= crit:
            state = "CRIT"
        elif v >= warn:
            state = "WARN"
    msg = label + ": " + str(v)
    return {"state": state, "metrics": metrics, "details": "", "msg": msg}

def _is_number(s):
    if s == None:
        return False
    if type(s) == "float" or type(s) == "int":
        return True
    if type(s) != "string":
        return False
    return s.lstrip("+-").replace(".", "", 1).isdigit()

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "Skype Data Proxy not available on this host (requires WMI/Windows)",
            "data": {"discovery": []},
        }
    item = params.get("item", "")
    return {
        "changed": False,
        "msg": "Skype Data Proxy not available on this host (requires WMI/Windows)",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }