def _parse_sap_hana_backup_v2(stdout):
    parsed = {}
    if not stdout:
        return parsed
    lines = stdout.splitlines()
    if len(lines) == 0:
        return parsed
    sid_instance = ""
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        # Agent format: first line is SID::instance, then lines are tab-separated fields
        if "::" in stripped and sid_instance == "":
            sid_instance = stripped.replace("::", " - ")
            continue
        parts = stripped.split("\t")
        if len(parts) >= 5:
            backup_id = parts[0]
            key = sid_instance + " - " + backup_id
            # Parse timestamp: remove fractional seconds (rsplit(".",1)[0])
            ts_raw = parts[1].rsplit(".", 1)[0]
            # Guard instead of try/except: validate format and extract components
            end_time = None
            if len(ts_raw) >= 19:
                if (ts_raw[4] == "-" and ts_raw[7] == "-" and ts_raw[10] == " " and
                    ts_raw[13] == ":" and ts_raw[16] == ":"):
                    year = ts_raw[0:4]
                    month = ts_raw[5:7]
                    day = ts_raw[8:10]
                    hour = ts_raw[11:13]
                    minute = ts_raw[14:16]
                    second = ts_raw[17:19]
                    if (year.isdigit() and month.isdigit() and day.isdigit() and
                        hour.isdigit() and minute.isdigit() and second.isdigit()):
                        end_time = ts_raw
            backup = {
                "end_time": end_time,
                "state_name": parts[2] if len(parts) > 2 else "",
                "comment": parts[3] if len(parts) > 3 else "",
                "message": parts[4] if len(parts) > 4 else "",
            }
            parsed[key] = backup
    return parsed


def main(ctx, params):
    # Discover mode: list all SAP HANA backup instances
    if params.get("_discover"):
        res = ctx.run(["hana_backup.sh", "--backup-info"], mutates=False)
        section = _parse_sap_hana_backup_v2(res.stdout)
        items = []
        for key in section:
            items.append({
                "item": key,
                "params": {"backup_age": (86400, 172800)},
                "metrics": ["backup_age"]
            })
        return {"changed": False, "msg": "discovered %d backup entries" % len(items),
                "data": {"discovery": items}}

    # Check mode: verify one item
    item = params.get("item", "")
    if item == "":
        fail("item is required for check mode")

    res = ctx.run(["hana_backup.sh", "--backup-info"], mutates=False)
    section = _parse_sap_hana_backup_v2(res.stdout)
    data = section.get(item)
    if data == None or len(data) == 0:
        return {"changed": False, "msg": "Login into database failed.",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_name = data.get("state_name", "")
    if state_name == "":
        return {"changed": False, "msg": "No backup found",
                "data": {"state": "WARN", "metrics": {}, "details": ""}}

    # Determine state from state_name
    state = "UNKNOWN"
    if state_name == "failed":
        state = "CRIT"
    elif state_name in ["cancel pending", "canceled"]:
        state = "WARN"
    elif state_name in ["ok", "successful", "running"]:
        state = "OK"

    msg_parts = ["Status: %s" % state_name]
    metrics = {}

    end_time = data.get("end_time")
    if end_time != None:
        msg_parts.append("Last: %s" % end_time)
        # Compute age using current epoch time
        now_res = ctx.run(["date", "+%s"], mutates=False)
        now_epoch = int(now_res.stdout.strip()) if now_res.stdout.strip().isdigit() else 0
        # Parse stored timestamp to epoch (approximate)
        # Extract components and convert manually
        if len(end_time) >= 19:
            year = int(end_time[0:4])
            month = int(end_time[5:7])
            day = int(end_time[8:10])
            hour = int(end_time[11:13])
            minute = int(end_time[14:16])
            second = int(end_time[17:19])
            # Simple epoch approximation (ignoring leap seconds/timezone)
            days = (year - 1970) * 365 + (year - 1969) // 4
            # Add days for months
            month_days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
            days += month_days[month - 1] + day - 1
            # Leap year adjustment for current year if past Feb
            if month > 2 and ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0):
                days += 1
            epoch = days * 86400 + hour * 3600 + minute * 60 + second
            age = now_epoch - epoch
            warn, crit = params.get("backup_age", (86400, 172800))
            if age >= crit:
                state = "CRIT"
            elif age >= warn and state != "CRIT":
                state = "WARN"
            metrics["backup_age"] = age

    comment = data.get("comment")
    if comment != "":
        msg_parts.append("Comment: %s" % comment)

    message = data.get("message")
    if message != "":
        msg_parts.append("Message: %s" % message)

    return {"changed": False, "msg": "; ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}