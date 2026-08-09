def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base_oid = "1.3.6.1.4.1.476.1.42.3.9.20.1"
    month_oid = base_oid + ".10.1.2.1.4868"
    year_oid = base_oid + ".20.1.2.1.4869"

    # Probe for the real Liebert device via sysObjectID.
    id_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                      host, "1.3.6.1.2.1.1.2.0"], mutates=False)
    if id_res.rc != 0 or ".1.3.6.1.4.1.476.1.42" not in id_res.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "no Liebert device found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no Liebert device found at " + host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Discovery mode
    if params.get("_discover"):
        for oid in [month_oid, year_oid]:
            r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                        mutates=False)
            if r.rc != 0:
                return {"changed": False, "msg": "no maintenance data found",
                        "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {"levels": (10, 5)},
                                         "metrics": ["time_left_days"]}]}}

    # Check mode for the single service
    month_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, month_oid],
                        mutates=False)
    year_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, year_oid],
                       mutates=False)
    if month_res.rc != 0 or year_res.rc != 0:
        return {"changed": False, "msg": "no maintenance data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    m_str = month_res.stdout.strip()
    y_str = year_res.stdout.strip()
    if not m_str or not y_str:
        return {"changed": False, "msg": "incomplete maintenance data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    month = int(m_str) if m_str.isdigit() else 0
    year = int(y_str) if y_str.isdigit() else 0
    if month == 0 or year == 0:
        return {"changed": False, "msg": "incomplete maintenance data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Compute days until next maintenance using a Julian-day calculation.
    mm = month
    yy = year
    if mm <= 2:
        mm = mm + 12
        yy = yy - 1
    aa = yy // 100
    bb = 2 - aa + aa // 4
    jd = int(365.25 * (yy + 4716)) + int(30.6001 * (mm + 1)) + 1 + bb - 1524
    maint_epoch = jd * 86400

    now_res = ctx.run(["date", "+%s"], mutates=False)
    now_str = now_res.stdout.strip()
    now_sec = int(now_str) if now_str.isdigit() else 0
    time_left_days = (maint_epoch - now_sec) // 86400

    warn_days, crit_days = params.get("levels", (10, 5))
    warn_days = warn_days[0] if hasattr(warn_days, "len") else warn_days
    crit_days = crit_days[0] if hasattr(crit_days, "len") else crit_days

    state = "OK"
    if time_left_days <= crit_days:
        state = "CRIT"
    elif time_left_days <= warn_days:
        state = "WARN"

    render = "%d days" % time_left_days if time_left_days > 0 else "%d days overdue" % (-time_left_days)
    return {"changed": False,
            "msg": "Next maintenance: %d/%d (%s)" % (month, year, render),
            "data": {"state": state, "metrics": {"time_left_days": time_left_days}, "details": render}}