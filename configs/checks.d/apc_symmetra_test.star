def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res_sys = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        sys_oid = ""
        for line in res_sys.stdout.splitlines():
            stripped = line.strip()
            if stripped.find(" = ") != -1:
                val = stripped.split(" = ", 1)[1].strip()
                if val.startswith(".1.3.6.1.4.1.318"):
                    sys_oid = val
                    break
        if sys_oid.startswith(".1.3.6.1.4.1.318"):
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }

    # Check mode
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.318.1.1.1.7.2.3"], mutates=False)
    res_date = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.318.1.1.1.7.2.4"], mutates=False)

    last_result = None
    for line in res_res.stdout.splitlines():
        stripped = line.strip()
        if stripped.find("3 = INTEGER:") != -1:
            parts = stripped.split("INTEGER:", 1)
            if len(parts) == 2 and parts[1].strip().isdigit():
                last_result = int(parts[1].strip())
                break

    last_date = ""
    for line in res_date.stdout.splitlines():
        stripped = line.strip()
        if stripped.find("4 = STRING:") != -1:
            parts = stripped.split("STRING:", 1)
            if len(parts) == 2:
                last_date = parts[1].strip().strip('"')
                break

    if last_result == None or last_date == "":
        return {
            "changed": False,
            "msg": "Data Missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    diagnostic_status_text = {1: "OK", 2: "failed", 3: "invalid", 4: "in progress"}

    test_state = "OK"
    if last_result == 2:
        test_state = "CRIT"
    elif last_result == 3 or last_result == 4:
        test_state = "WARN"

    # Parse date and compute days_diff — guard instead of try/except
    date_parts = last_date.split("/")
    days_diff = 0
    if len(date_parts) == 3:
        month_str = date_parts[0].strip()
        day_str = date_parts[1].strip()
        year_str = date_parts[2].strip()
        if month_str.isdigit() and day_str.isdigit() and year_str.isdigit():
            month = int(month_str)
            day = int(day_str)
            year = int(year_str)
            if year < 100:
                year += 2000
            # Get today's date components via shell
            date_cmd = ctx.run(["date", "+%Y %m %d"], mutates=False)
            today_parts = date_cmd.stdout.strip().split()
            if len(today_parts) == 3 and today_parts[0].isdigit() and today_parts[1].isdigit() and today_parts[2].isdigit():
                today_year = int(today_parts[0])
                today_month = int(today_parts[1])
                today_day = int(today_parts[2])
                # Compute days since test using epoch seconds
                test_date_str = "%d-%d-%d" % (year, month, day)
                test_epoch_res = ctx.run(["sh", "-c", "date -d \"" + test_date_str + "\" +%s"], mutates=False)
                today_epoch_res = ctx.run(["date", "+%s"], mutates=False)
                test_e_str = test_epoch_res.stdout.strip()
                today_e_str = today_epoch_res.stdout.strip()
                if test_e_str.lstrip('-').isdigit() and today_e_str.lstrip('-').isdigit():
                    test_e = int(test_e_str)
                    today_e = int(today_e_str)
                    days_diff = (today_e - test_e) // 86400
            else:
                return {
                    "changed": False,
                    "msg": "Date of last self test is unknown",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
        else:
            return {
                "changed": False,
                "msg": "Date of last self test is unknown",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
    else:
        return {
            "changed": False,
            "msg": "Date of last self test is unknown",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply levels
    state = test_state
    levels = params.get("levels_elapsed_time", ["no_levels", None])
    if levels[0] == "fixed":
        warn = levels[1][0]
        crit = levels[1][1]
        if days_diff >= crit:
            state = "CRIT"
        elif days_diff >= warn:
            state = "WARN"

    summary = "Result of self test: %s, Date of last test: %s" % (diagnostic_status_text.get(last_result, "-"), last_date)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""}
    }