def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "curl", "-s", "-H", "X-Cisco-Meraki-API-Key: %s" % params.get("api_key", ""),
            "https://api.meraki.com/api/v1/devices/%s/sensorReadings/latest" % params.get("device_serial", "")
        ], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        data = json.decode(res.stdout)

        if not isinstance(data, list) or len(data) == 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        readings = []
        if isinstance(data[0], dict):
            readings = data[0].get("readings", []) if isinstance(data[0].get("readings"), list) else []

        has_battery = False
        for r in readings:
            if isinstance(r, dict) and r.get("metric") == "battery":
                has_battery = True
                break

        if has_battery:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "Sensor", "params": {}, "metrics": ["battery_capacity"]}]}}

        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    item = params.get("item", "Sensor")
    if item != "Sensor":
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run([
        "curl", "-s", "-H", "X-Cisco-Meraki-API-Key: %s" % params.get("api_key", ""),
        "https://api.meraki.com/api/v1/devices/%s/sensorReadings/latest" % params.get("device_serial", "")
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "sensor data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)

    if not isinstance(data, list) or len(data) == 0:
        return {"changed": False, "msg": "sensor data malformed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    readings = []
    if isinstance(data[0], dict):
        readings = data[0].get("readings", []) if isinstance(data[0].get("readings"), list) else []

    battery = None
    for r in readings:
        if isinstance(r, dict) and r.get("metric") == "battery":
            battery = r
            break

    if battery == None:
        return {"changed": False, "msg": "no battery reading available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    percentage = None
    if "percentage" in battery:
        pct_val = battery.get("percentage")
        if isinstance(pct_val, int) or (isinstance(pct_val, str) and pct_val.isdigit()):
            percentage = int(pct_val)
    elif "relativePercentage" in battery:
        pct_val = battery.get("relativePercentage")
        if isinstance(pct_val, int) or (isinstance(pct_val, str) and pct_val.isdigit()):
            percentage = int(pct_val)
    else:
        return {"changed": False, "msg": "no battery percentage available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    timestamp = battery.get("ts")
    ts_val = None
    if timestamp != None and isinstance(timestamp, str):
        ts_str = timestamp
        if ts_str.endswith("Z"):
            ts_str = ts_str[:-1] + "+00:00"
        if "T" in ts_str:
            date_part, time_part = ts_str.split("T", 1)
            date_parts = date_part.split("-")
            if len(date_parts) >= 3:
                if date_parts[0].isdigit() and date_parts[1].isdigit() and date_parts[2].isdigit():
                    year = int(date_parts[0])
                    month = int(date_parts[1])
                    day = int(date_parts[2])
                    time_part = time_part.split("+")[0]
                    if "-" in time_part:
                        time_part = time_part.split("-")[0]
                    hms = time_part.split(":")
                    if len(hms) >= 3:
                        if hms[0].isdigit() and hms[1].isdigit() and (hms[2].replace(".", "").isdigit() if "." in hms[2] else hms[2].isdigit()):
                            hour = int(hms[0])
                            minute = int(hms[1])
                            second = float(hms[2]) if "." in hms[2] else int(hms[2])
                            days = (year - 1970) * 365 + ((year - 1969) // 4) - ((year - 1901) // 100) + ((year - 1601) // 400)
                            month_days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
                            days += month_days[month - 1] + day - 1
                            if month > 2 and ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0):
                                days += 1
                            ts_val = days * 86400 + hour * 3600 + minute * 60 + int(second)

    warn_upper = params.get("levels", None)
    crit_upper = params.get("levels", None)
    warn_lower = params.get("levels_lower", None)
    crit_lower = params.get("levels_lower", None)

    state = "OK"
    msg_parts = []

    if percentage != None:
        if crit_upper != None and percentage >= crit_upper:
            state = "CRIT"
        elif warn_upper != None and percentage >= warn_upper:
            state = "WARN"

        if crit_lower != None and percentage <= crit_lower:
            state = "CRIT"
        elif warn_lower != None and percentage <= warn_lower:
            state = "WARN"

        msg_parts.append("Battery: %d%%" % percentage)
        metrics = {"battery_capacity": percentage}
    else:
        return {"changed": False, "msg": "no battery percentage available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    now = ctx.run(["date", "+%s"], mutates=False)
    if now.rc == 0 and now.stdout.strip().isdigit():
        now_ts = int(now.stdout.strip())
        if ts_val != None and now_ts >= ts_val:
            age = now_ts - ts_val
            last_levels = params.get("last_reported_levels")
            if last_levels != None and isinstance(last_levels, list) and len(last_levels) >= 2:
                warn_age = last_levels[0]
                crit_age = last_levels[1]
                if crit_age != None and age >= crit_age:
                    state = "CRIT"
                elif warn_age != None and age >= warn_age:
                    state = "WARN"
            hours = age // 3600
            mins = (age % 3600) // 60
            secs = age % 60
            age_str = ""
            if hours > 0:
                age_str += "%dh " % hours
            if mins > 0 or hours > 0:
                age_str += "%dm " % mins
            age_str += "%ds" % secs
            msg_parts.append("since last report: " + age_str)
        elif ts_val != None:
            msg_parts.append("since last report: %d seconds" % (now_ts - ts_val))
    else:
        if ts_val != None:
            msg_parts.append("since last report: unknown (time probe failed)")

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        },
    }