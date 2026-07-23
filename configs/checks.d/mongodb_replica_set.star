def _parse_date(date_val):
    """Parse MongoDB $date field (ms integer or ISO-8601 string) to epoch seconds."""
    if date_val == None:
        return 0.0
    if type(date_val) == "int":
        return date_val / 1000.0
    s = str(date_val).strip()
    if 'T' not in s:
        return 0.0
    date_part, time_part = s.split('T', 1)
    time_part = time_part.rstrip('Z')
    ymd = date_part.split('-')
    if len(ymd) < 3:
        return 0.0
    year = int(ymd[0])
    month = int(ymd[1])
    day = int(ymd[2])
    hms_parts = time_part.split(':')
    if len(hms_parts) < 2:
        return 0.0
    hour = int(hms_parts[0])
    minute = int(hms_parts[1])
    sec_str = hms_parts[2] if len(hms_parts) > 2 else "0"
    if '.' in sec_str:
        sec_int = int(sec_str.split('.')[0])
        frac_str = sec_str.split('.')[1]
        frac = float("0." + frac_str)
    else:
        sec_int = int(sec_str)
        frac = 0.0
    second = sec_int + frac
    def is_leap(y):
        return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)
    days = 0
    for y in range(1970, year):
        days += 366 if is_leap(y) else 365
    month_days = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if is_leap(year):
        month_days[2] = 29
    for m in range(1, month):
        days += month_days[m]
    days += day - 1
    return days * 86400 + hour * 3600 + minute * 60 + second


def _get_primary(members):
    primary = {}
    secondaries = []
    for m in members:
        state = m.get("state", -1)
        if state == 1:
            primary = m
        elif state != 7:
            secondaries.append(m)
    return primary, secondaries


def main(ctx, params):
    res = ctx.run(["cat", "/var/lib/mongodb-agent/agent-data/mongodb_replica_set.json"], mutates=False)
    if not res.stdout or res.rc != 0:
        return {"changed": False, "msg": "no data (agent section not present)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "invalid JSON data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = json.decode(res.stdout)

    if params.get("_discover"):
        if section and section.get("members"):
            return {"changed": False, "msg": "discovered MongoDB replication lag service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": ["replication_lag"]}]}}
        else:
            return {"changed": False, "msg": "no replica set members found",
                    "data": {"discovery": []}}

    members = section.get("members", [])
    num_members = len(members)
    if num_members <= 1:
        return {"changed": False, "msg": "Number of members is %d" % num_members,
                "data": {"state": "WARN", "metrics": {}, "details": ""}}

    primary, secondaries = _get_primary(members)
    if not primary and not secondaries:
        return {"changed": False, "msg": "no valid members found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    start_ts = 0.0
    primary_name = "unknown"
    if primary:
        start_ts = _parse_date(primary.get("optimeDate", {}).get("$date", 0))
        primary_name = primary.get("name", "primary")
    else:
        for m in secondaries:
            ts = _parse_date(m.get("optimeDate", {}).get("$date", 0))
            if ts > start_ts:
                start_ts = ts
                primary_name = "freshest member (%s, no primary available)" % m.get("name", "unknown")

    if start_ts == 0.0:
        return {"changed": False, "msg": "could not determine replication timestamp",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels_mongdb_replication_lag", (10, 60, 3600))

    worst_state = "OK"
    msg_parts = []
    metrics = {}

    for member in secondaries:
        member_name = member.get("name", "unknown")
        member_optime_ts = _parse_date(member.get("optimeDate", {}).get("$date", 0))
        if member_optime_ts == 0.0:
            msg_parts.append("%s: no replication info yet, State: %s" % (member_name, member.get("state", 0)))
            if worst_state == "OK":
                worst_state = "OK"
            continue

        lag_sec = start_ts - member_optime_ts
        if lag_sec < 0:
            lag_sec = 0.0

        if lag_sec >= levels[2]:
            state = "CRIT"
        elif lag_sec >= levels[1]:
            state = "WARN"
        elif lag_sec >= levels[0]:
            state = "WARN"
        else:
            state = "OK"

        if state == "CRIT":
            worst_state = "CRIT"
        elif state == "WARN" and worst_state != "CRIT":
            worst_state = "WARN"

        metrics[member_name.replace(".", "_")] = lag_sec
        msg_parts.append("member %s lag: %ds" % (member_name, int(lag_sec)))

    final_msg = "Replication lag: " + "; ".join(msg_parts) if msg_parts else "No secondaries"
    return {
        "changed": False,
        "msg": final_msg,
        "data": {"state": worst_state, "metrics": metrics, "details": ""},
    }