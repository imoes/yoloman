def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_res.rc != 0 or sys_res.rc == 127:
            return {"changed": False, "msg": "kentix not present",
                    "data": {"discovery": []}}

        sys_oid = sys_res.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.332.11.6"):
            return {"changed": False, "msg": "kentix not present",
                    "data": {"discovery": []}}

        sensors = _read_motion_sensors(ctx, host, community)
        out = []
        for index in sensors:
            out.append({"item": index, "params": {}, "metrics": ["motion"]})
        return {"changed": False,
                "msg": "discovered %d sensors" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sensors = _read_motion_sensors(ctx, host, community)
    if item == "" or item not in sensors:
        return {"changed": False, "msg": "no such sensor: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor = sensors[item]
    today = _localtime(ctx)
    weekdays = ("monday", "tuesday", "wednesday", "thursday",
                "friday", "saturday", "sunday")
    if "time_periods" in params:
        periods = params["time_periods"].get(weekdays[today["wday"]], [((0, 0), (24, 0))])
    else:
        periods = [((0, 0), (24, 0))]

    if sensor["value"] >= sensor["maximum"]:
        in_period = _test_in_period((today["hour"], today["min"]), periods)
        state = "WARN" if in_period else "OK"
        msg = "Motion detected"
    else:
        state = "OK"
        msg = "No motion detected"

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"motion": sensor["value"]},
                     "details": msg}}


def _read_motion_sensors(ctx, host, community):
    sensors = {}
    bases = [
        ".1.3.6.1.4.1.37954.2.1.5",
        ".1.3.6.1.4.1.37954.3.1.5",
    ]
    for base in bases:
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base],
            mutates=False,
        )
        if res.rc != 0:
            continue
        rows = {}
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            suffix = oid[len(base):]
            parts = suffix.split(".")
            if len(parts) < 3:
                continue
            col = parts[1]
            index = parts[2]
            if index not in rows:
                rows[index] = {}
            rows[index][col] = value
        for index in rows:
            r = rows[index]
            if "0" in r and "1" in r and "2" in r:
                sensors[index] = {
                    "value": int(r["1"]) if _is_int(r["1"]) else 0,
                    "maximum": int(r["2"]) if _is_int(r["2"]) else 0,
                }
    return sensors


def _test_in_period(time_tuple, periods):
    time_mins = time_tuple[0] * 60 + time_tuple[1]
    for per in periods:
        low = per[0]
        high = per[1]
        per_mins_low = low[0] * 60 + low[1]
        per_mins_high = high[0] * 60 + high[1]
        if per_mins_low <= time_mins and time_mins < per_mins_high:
            return True
    return False


def _localtime(ctx):
    res = ctx.run(["date", "+%w %H %M %S"], mutates=False)
    parts = res.stdout.strip().split()
    if len(parts) < 4:
        return {"wday": 0, "hour": 0, "min": 0, "sec": 0}
    wday = int(parts[0])
    wday_adj = (wday - 1) % 7
    return {"wday": wday_adj, "hour": int(parts[1]), "min": int(parts[2]), "sec": int(parts[3])}


def _is_int(s):
    s2 = s
    if s2.startswith("-"):
        s2 = s2[1:]
    return s2.isdigit() and len(s2) > 0