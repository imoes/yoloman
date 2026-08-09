def main(ctx, params):
    if params.get("_discover"):
        agent = ctx.run(["mobileiron_agent", "--version"], mutates=False)
        if agent.rc == 127:
            return {"changed": False, "msg": "no mobileiron agent found",
                    "data": {"discovery": []}}
        if agent.rc != 0:
            return {"changed": False, "msg": "mobileiron agent probe failed",
                    "data": {"discovery": []}}
        entry = {"item": "", "params": {"non_compliant_summary_levels": (10.0, 20.0)},
                 "metrics": ["mobileiron_devices_total", "mobileiron_non_compliant",
                             "mobileiron_non_compliant_summary"]}
        return {"changed": False, "msg": "discovered 1 mobileiron source host",
                "data": {"discovery": [entry]}}

    res = ctx.run(["mobileiron_agent", "--source-host"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "no mobileiron agent found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "mobileiron agent query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)
    total = data.get("total_count", 0)
    non_compliant = data.get("non_compliant", 0)
    non_compliant_percent = 0.0
    if total > 0:
        non_compliant_percent = non_compliant / total * 100.0

    levels = params.get("non_compliant_summary_levels", (10.0, 20.0))
    warn = levels[0] if len(levels) >= 1 else 10.0
    crit = levels[1] if len(levels) >= 2 else 20.0

    state = "OK"
    if non_compliant_percent >= crit:
        state = "CRIT"
    elif non_compliant_percent >= warn:
        state = "WARN"

    pct_rounded = int(non_compliant_percent * 10 + 0.5) / 10.0
    msg = "Non-compliant: %d, Total: %d (%s%% non-compliant)" % (
        non_compliant, total, str(pct_rounded))

    metrics = {
        "mobileiron_devices_total": total,
        "mobileiron_non_compliant": non_compliant,
        "mobileiron_non_compliant_summary": non_compliant_percent,
    }

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}