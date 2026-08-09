def parse_date(date):
    if type(date) == "string":
        n = len(date)
        y = 0
        mo = 0
        d = 0
        h = 0
        mi = 0
        s = 0
        frac = 0
        if n >= 10 and date[4] == "-" and date[7] == "-":
            y = int(date[0:4])
            mo = int(date[5:7])
            d = int(date[8:10])
            if n >= 19 and (date[10] == "T" or date[10] == " "):
                h = int(date[11:13])
                mi = int(date[14:16])
                s = int(date[17:19])
                if n > 19 and (date[19] == "." or date[19] == ","):
                    frac_str = date[20:]
                    end = 0
                    for i in range(len(frac_str)):
                        c = frac_str[i]
                        if c in ("Z", "+", "-", " "):
                            end = i
                            break
                        end = i + 1
                    if end > 0:
                        frac = int(frac_str[0:end].ljust(3, "0")[0:3]) / 1000.0 if end >= 3 else float("0." + frac_str[0:end])
        import_days = _days_from_civil(y, mo, d)
        ts = (import_days + (h * 3600 + mi * 60 + s) - 718766 * 86400) + frac
        return float(ts)
    return date / 1000.0

def _days_from_civil(year, month, day):
    y = year
    m = month
    dd = day
    if y < 0:
        y = y - 1
    era = y // 400
    yoe = y - era * 400
    moffset = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    doy = moffset[m - 1] + dd - 1
    if m <= 2 and ((yoe % 4 == 0 and yoe % 100 != 0) or yoe % 400 == 0):
        doy = doy + 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return (era * 146097) + doe - 718766

def _get_primary(members):
    primary = {}
    secondaries = []
    for member in members:
        st = member.get("state", -1)
        if st == 1:
            primary = member
            continue
        if st == 7:
            continue
        secondaries.append(member)
    return primary, secondaries

def _round(x):
    return int(x + 0.5)

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mongosh", "--quiet", "--eval", "printjson(db.adminCommand({replSetGetStatus: 1, details: false}))"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "mongosh not installed", "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout or res.stdout.strip() == "" or res.stdout.strip() == "null":
            return {"changed": False, "msg": "no replica set found", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        if not data or not data.get("members"):
            return {"changed": False, "msg": "no replica set members", "data": {"discovery": []}}
        levels = (10, 60, 3600)
        return {"changed": False, "msg": "discovered 1 replica set", "data": {"discovery": [{"item": "", "params": {"levels_mongdb_replication_lag": levels}, "metrics": ["replication_lag"]}]}}

    item = params.get("item", "")
    res = ctx.run(["mongosh", "--quiet", "--eval", "printjson(db.adminCommand({replSetGetStatus: 1, details: false}))"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "mongosh not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout or res.stdout.strip() == "" or res.stdout.strip() == "null":
        return {"changed": False, "msg": "no replica set accessible", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if not data or not data.get("members"):
        return {"changed": False, "msg": "no replica set members", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    members = data.get("members", [])
    n_members = len(members)
    if n_members <= 1:
        return {"changed": False, "msg": "Number of members is %d" % n_members, "data": {"state": "WARN", "metrics": {}, "details": ""}}

    primary, secondaries = _get_primary(members)

    start_ts = 0.0
    name = "unknown"
    if primary:
        start_ts = parse_date(primary.get("optimeDate", {}).get("$date", 0))
        name = "primary (%s)" % primary.get("name", "unknown")
    else:
        best_idx = -1
        for index in range(len(secondaries)):
            timestamp = parse_date(secondaries[index].get("optimeDate", {}).get("$date", 0))
            if timestamp > start_ts:
                start_ts = timestamp
                name = "freshest member (%s, no primary available at the moment)" % secondaries[index].get("name", "unknown")
                best_idx = index
        if best_idx != -1:
            secondaries = secondaries[:best_idx] + secondaries[best_idx + 1:]

    levels = params.get("levels_mongdb_replication_lag", (10, 60, 3600))
    lag_threshold = levels[0]
    warn_level = levels[1]
    crit_level = levels[2]

    worst_state = "OK"
    details_lines = []
    metrics = {}

    for member in secondaries:
        member_name = member.get("name", "unknown")
        optime = member.get("optime", {})
        ts = optime.get("ts", {})
        timestamp_val = ts.get("$timestamp", {}).get("t", None)

        if timestamp_val:
            member_optime_date = parse_date(member.get("optimeDate", {}).get("$date", 0))
            replication_lag_sec = start_ts - member_optime_date

            if replication_lag_sec > lag_threshold:
                check_levels = (warn_level, crit_level)
                state = "OK"
                if replication_lag_sec >= check_levels[1]:
                    state = "CRIT"
                elif replication_lag_sec >= check_levels[0]:
                    state = "WARN"
                if state == "CRIT" and worst_state != "CRIT":
                    worst_state = state
                elif state == "WARN" and worst_state == "OK":
                    worst_state = state
                metrics["replication_lag_" + member_name] = int(replication_lag_sec)
                hours = _round((replication_lag_sec / 36) / 100.0)
                details_lines.append("member (%s) is %ds (%sh) behind %s" % (member_name, _round(replication_lag_sec), hours, name))
            else:
                metrics["replication_lag_" + member_name] = 0
                details_lines.append("%s: lag within normal range" % member_name)
            metrics["replication_lag"] = int(replication_lag_sec)
        else:
            details_lines.append("%s: no replication info yet, State: %s" % (member_name, member.get("state", 0)))

    summary = "checked %d secondaries against %s" % (len(secondaries), name)
    details = "\n".join(details_lines) if details_lines else ""
    return {"changed": False, "msg": summary, "data": {"state": worst_state, "metrics": metrics, "details": details}}