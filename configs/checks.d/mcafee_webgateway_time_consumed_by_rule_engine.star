# Starlark check: mcafee_webgateway_time_consumed_by_rule_engine
# Source: cmk/plugins/mcafee/agent_based/mcafee_webgateway_time_consumed_by_rule_engine.py
# Section: webgateway_misc — data at /var/lib/mcafee-webgateway/misc.json
# Defaults: warn=1500ms (1.5s), crit=2000ms (2.0s) per libgateway.MISC_DEFAULT_PARAMS
#           get_param_in_seconds divides ms values by 1000.

DATA_PATH = "/var/lib/mcafee-webgateway/misc.json"

def _format_timespan(seconds):
    if seconds < 60.0:
        return "%f s" % seconds
    mins = int(seconds) // 60
    secs = seconds - float(mins * 60)
    if mins < 60:
        return "%d min %f s" % (mins, secs)
    hours = mins // 60
    mins_rem = mins % 60
    return "%d h %d min %f s" % (hours, mins_rem, secs)

def main(ctx, params):
    if params.get("_discover"):
        if not ctx.file_exists(DATA_PATH):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        content = ctx.file_read(DATA_PATH)
        if not content.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        data = json.decode(content)
        if data.get("time_consumed_by_rule_engine") == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{
                "item": "",
                "params": {"warn": 1.5, "crit": 2.0},
                "metrics": ["time_consumed_by_rule_engine"],
            }]},
        }

    if not ctx.file_exists(DATA_PATH):
        return {"changed": False, "msg": "data file missing: " + DATA_PATH,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read(DATA_PATH)
    if not content.strip():
        return {"changed": False, "msg": "data file empty: " + DATA_PATH,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(content)
    raw = data.get("time_consumed_by_rule_engine")
    if raw == None:
        return {"changed": False, "msg": "time_consumed_by_rule_engine not in data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    seconds = float(raw)

    # Thresholds come in seconds; Checkmk default: 1500ms=1.5s / 2000ms=2.0s
    warn = float(params.get("warn", 1.5))
    crit = float(params.get("crit", 2.0))

    state = "OK"
    if seconds >= crit:
        state = "CRIT"
    elif seconds >= warn:
        state = "WARN"

    ts = _format_timespan(seconds)
    msg = "Time consumed by rule engine: " + ts
    if state == "WARN":
        msg = msg + " (warn at " + _format_timespan(warn) + ")"
    elif state == "CRIT":
        msg = msg + " (crit at " + _format_timespan(crit) + ")"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"time_consumed_by_rule_engine": seconds},
            "details": "",
        },
    }