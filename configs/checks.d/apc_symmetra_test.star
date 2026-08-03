def _days_since_epoch(y, m, day):
    if m <= 2:
        y = y - 1
        m = m + 12
    a = y // 100
    b = 2 - a + a // 4
    jd = int(365.25 * (y + 4716)) + int(30.6001 * (m + 1)) + day + b - 1524
    return jd

_TODAY_JD = _days_since_epoch(2025, 1, 1)

diagnostic_status_text = {1: "OK", 2: "failed", 3: "invalid", 4: "in progress"}


def _parse_date(last_date):
    parts = last_date.split("/")
    if len(parts) != 3:
        return None
    if not (parts[0].isdigit() and parts[1].isdigit() and parts[2].isdigit()):
        return None
    month = int(parts[0])
    day = int(parts[1])
    year = int(parts[2])
    if year < 100:
        year = year + 2000
    if month < 1 or month > 12:
        return None
    if day < 1 or day > 31:
        return None
    return (year, month, day)


def _snmp_get_int(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val.isdigit():
        return int(val)
    return None


def _snmp_get_str(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        sys_oid_val = _snmp_get_str(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if sys_oid_val == None:
            return {"changed": False, "msg": "no APC device detected", "data": {"discovery": []}}
        if not sys_oid_val.startswith(".1.3.6.1.4.1.318"):
            return {"changed": False, "msg": "not an APC device", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {"levels_elapsed_time": ("no_levels", None)}, "metrics": ["self_test_days"]}
                ]
            },
        }

    diag_oid = ".1.3.6.1.4.1.318.1.1.1.7.2.3"
    date_oid = ".1.3.6.1.4.1.318.1.1.1.7.2.4"
    last_result = _snmp_get_int(ctx, host, community, diag_oid)
    last_date = _snmp_get_str(ctx, host, community, date_oid)

    if last_result == None or last_date == None:
        return {
            "changed": False,
            "msg": "no self-test data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP query failed"},
        }

    test_state = "OK"
    if last_result == 2:
        test_state = "CRIT"
    elif last_result == 3:
        test_state = "WARN"

    parsed = _parse_date(last_date)
    days_diff = None
    if parsed != None:
        y, mo, d = parsed
        today_jd = _days_since_epoch(2025, 1, 1)
        result_jd = _days_since_epoch(y, mo, d)
        days_diff = today_jd - result_jd

    elapsed = params.get("levels_elapsed_time", ("no_levels", None))
    elapsed_state = "OK"
    if type(elapsed) == "list" and len(elapsed) == 2 and elapsed[0] == "fixed":
        levels = elapsed[1]
        if type(levels) == "list" and len(levels) >= 2:
            warn_val = levels[0]
            crit_val = levels[1]
            if days_diff != None and warn_val != None and crit_val != None:
                if days_diff >= crit_val:
                    elapsed_state = "CRIT"
                elif days_diff >= warn_val:
                    elapsed_state = "WARN"

    final_state = "OK"
    if test_state == "CRIT" or elapsed_state == "CRIT":
        final_state = "CRIT"
    elif test_state == "WARN" or elapsed_state == "WARN":
        final_state = "WARN"

    days_metric = 0
    if days_diff != None:
        days_metric = days_diff

    msg = "Result of self test: %s, Date of last test: %s" % (
        diagnostic_status_text.get(last_result, "-"),
        last_date,
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": final_state,
            "metrics": {"self_test_days": days_metric},
            "details": "",
        },
    }