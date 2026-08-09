def _parse_settings(text):
    states = {}
    settings = {}
    for line in text.splitlines():
        f = line.split()
        if len(f) == 2:
            for what in ["Health", "State"]:
                if f[0] == what:
                    states[what] = f[1]
        elif len(f) == 3 and f[1] == "Synchronized":
            settings[f[0]] = f[2]
    return states, settings

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["acmecli", "show", "health"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "acme_sbc not available (rc=%d)" % res.rc,
                    "data": {"discovery": []}}
        states, settings = _parse_settings(res.stdout)
        if not settings and not states:
            return {"changed": False, "msg": "no acme_sbc data found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 settings service",
                "data": {"discovery": [
                    {"item": "", "params": dict(settings),
                     "metrics": []}]}}

    res = ctx.run(["acmecli", "show", "health"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "acme_sbc not available (rc=%d)" % res.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    states, current_settings = _parse_settings(res.stdout)
    if not current_settings and not states:
        return {"changed": False, "msg": "no acme_sbc data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    saved_settings = params
    msgs = []
    worst = "OK"
    for setting, value in saved_settings.items():
        cur = current_settings.get(setting)
        if cur != value:
            msgs.append("%s changed from %s to %s" % (setting, value, cur))
            worst = "CRIT"
    summary = "Checking %d settings" % len(saved_settings)
    if msgs:
        summary = summary + "; " + "; ".join(msgs)
    return {"changed": False, "msg": summary,
            "data": {"state": worst, "metrics": {}, "details": ""}}