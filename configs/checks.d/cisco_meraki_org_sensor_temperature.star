def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/cmk-agent/cisco_meraki_org_sensor_readings"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout) if res.stdout.strip() else None
        if data == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        if not isinstance(data, list) or len(data) == 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        payload = data[0] if isinstance(data, list) else data
        if not isinstance(payload, dict):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        readings = payload.get("readings", [])
        if not isinstance(readings, list):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        has_temperature = False
        for r in readings:
            if isinstance(r, dict) and r.get("metric") == "temperature":
                has_temperature = True
                break
        if has_temperature:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "Sensor", "params": {"levels": (50.0, 60.0)},
                                            "metrics": ["temperature"]}]}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/cmk-agent/cisco_meraki_org_sensor_readings"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if data == None or not isinstance(data, list) or len(data) == 0:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    payload = data[0] if isinstance(data, list) else data
    if not isinstance(payload, dict):
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    readings = payload.get("readings", [])
    if not isinstance(readings, list):
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temperature = None
    ts = None
    for r in readings:
        if isinstance(r, dict) and r.get("metric") == "temperature":
            readings_dict = r
            if "celsius" in readings_dict:
                temperature = float(readings_dict["celsius"])
            if "ts" in readings_dict:
                ts_str = readings_dict["ts"]
                if ts_str and len(ts_str) >= 5:
                    # Manual ISO-like timestamp parsing for basic "YYYY-MM-DDTHH:MM:SSZ" format
                    year_str = ts_str[0:4] if len(ts_str) >= 4 else ""
                    month_str = ts_str[5:7] if len(ts_str) >= 7 else ""
                    day_str = ts_str[8:10] if len(ts_str) >= 10 else ""
                    hour_str = ts_str[11:13] if len(ts_str) >= 13 else ""
                    minute_str = ts_str[14:16] if len(ts_str) >= 16 else ""
                    second_str = ts_str[17:19] if len(ts_str) >= 19 else ""
                    if year_str.isdigit() and month_str.isdigit() and day_str.isdigit() and \
                       hour_str.isdigit() and minute_str.isdigit() and second_str.isdigit():
                        year = int(year_str)
                        month = int(month_str)
                        day = int(day_str)
                        hour = int(hour_str)
                        minute = int(minute_str)
                        second = int(second_str)
                        # Approximate Unix timestamp (ignores leap seconds and leap years precisely)
                        days = _days_since_epoch(year, month, day)
                        seconds_in_day = hour * 3600 + minute * 60 + second
                        ts = days * 86400 + seconds_in_day
            break
    if temperature == None:
        return {"changed": False, "msg": "no temperature reading available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("levels", (50.0, 60.0))
    warn = levels[0] if isinstance(levels, list) else levels
    crit = levels[1] if isinstance(levels, list) else levels
    if temperature >= crit:
        state = "CRIT"
    elif temperature >= warn:
        state = "WARN"
    else:
        state = "OK"
    msg = "Temperature: %f C" % temperature
    if ts != None:
        current_time = ctx.run(["date", "+%s"], mutates=False)
        if current_time.rc == 0:
            current_ts_str = current_time.stdout.strip()
            if current_ts_str.isdigit():
                current_ts = int(current_ts_str)
                age = current_ts - ts
                if age >= 0:
                    msg += ", Age: %f s" % age
                else:
                    msg += ", Age: negative (clock skew)"
    metrics = {"temperature": temperature}
    if ts != None:
        current_time = ctx.run(["date", "+%s"], mutates=False)
        if current_time.rc == 0:
            current_ts_str = current_time.stdout.strip()
            if current_ts_str.isdigit():
                current_ts = int(current_ts_str)
                age = current_ts - ts
                if age >= 0:
                    metrics["last_reported"] = age
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _days_since_epoch(year, month, day):
    # Approximate days since Unix epoch (1970-01-01), ignoring leap second edge cases
    y = year
    m = month
    d = day
    if m <= 2:
        y -= 1
        m += 12
    days = 365 * y + y // 4 - y // 100 + y // 400
    days += (153 * (m - 3) + 2) // 5 + d - 1
    days -= 719528  # days from year 0 to 1970-01-01
    return days