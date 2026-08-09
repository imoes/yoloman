def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["sansymphony_alerts_probe"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "sansymphony not installed",
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "no sansymphony data",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        return {"changed": False, "msg": "discovered sansymphony alerts",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": (1, 2)}, "metrics": ["alerts"]}
                ]}}

    res = ctx.run(["sansymphony_alerts_probe"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "sansymphony not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "no sansymphony data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    nr_of_alerts = int(data.get("alerts", 0))
    levels = params.get("levels", (1, 2))
    warn, crit = levels[0], levels[1]
    if nr_of_alerts >= crit:
        state = "CRIT"
    elif nr_of_alerts >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False,
            "msg": "Unacknowlegded alerts: %d" % nr_of_alerts,
            "data": {"state": state, "metrics": {"alerts": nr_of_alerts}, "details": ""}}