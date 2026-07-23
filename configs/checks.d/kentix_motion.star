def main(ctx, params):
    _WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
    KENTIX_BASE_OID_1 = ".1.3.6.1.4.1.37954.2.1.5"
    KENTIX_BASE_OID_2 = ".1.3.6.1.4.1.37954.3.1.5"
    KENTIX_OID_END = ".1.3.6.1.2.1.1.2.0"
    KENTIX_MODEL_OID = ".1.3.6.1.4.1.332.11.6"

    # Detect Kentix devices
    res_sysobj = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          params.get("host", "localhost"), KENTIX_OID_END], mutates=False)
    sysobj_line = res_sysobj.stdout.strip()
    if not sysobj_line.startswith(KENTIX_MODEL_OID):
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "not a Kentix device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Collect all indices from both trees
    indices = set()
    for base_oid in [KENTIX_BASE_OID_1, KENTIX_BASE_OID_2]:
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       params.get("host", "localhost"), base_oid], mutates=False)
        if res.rc != 0 or not res.stdout:
            continue
        for line in res.stdout.splitlines():
            if "=" not in line:
                continue
            left = line.split("=", 1)[0].strip()
            parts = left.split(".")
            if len(parts) >= 10:
                idx_str = parts[-1]
                if idx_str.isdigit():
                    indices.add(int(idx_str))

    # Build sensors dict
    sensors = {}
    for idx in indices:
        for base_oid in [KENTIX_BASE_OID_1, KENTIX_BASE_OID_2]:
            value_oid = "%s.1.%d" % (base_oid, idx)
            max_oid = "%s.2.%d" % (base_oid, idx)

            res_val = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                               params.get("host", "localhost"), value_oid], mutates=False)
            res_max = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                               params.get("host", "localhost"), max_oid], mutates=False)

            if res_val.rc != 0 or not res_val.stdout:
                continue
            if res_max.rc != 0 or not res_max.stdout:
                continue

            val_line = res_val.stdout.strip()
            max_line = res_max.stdout.strip()

            # Extract integer values
            val = 0
            if val_line.startswith("INTEGER:"):
                v_str = val_line.split(":", 1)[1].strip()
                val = int(v_str) if v_str.lstrip("-").isdigit() else 0

            maximum = 0
            if max_line.startswith("INTEGER:"):
                m_str = max_line.split(":", 1)[1].strip()
                maximum = int(m_str) if m_str.lstrip("-").isdigit() else 0

            # Update sensor entry (use the first valid reading we get)
            if str(idx) not in sensors:
                sensors[str(idx)] = {"value": val, "maximum": maximum}
            else:
                # Prefer non-zero values
                if val > 0:
                    sensors[str(idx)]["value"] = val
                if maximum > 0:
                    sensors[str(idx)]["maximum"] = maximum

    # Discovery mode
    if params.get("_discover"):
        items = []
        for idx_str in sensors:
            items.append({"item": idx_str, "params": {}, "metrics": ["motion"]})
        return {"changed": False, "msg": "discovered %d motion detectors" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    sensor = sensors.get(item)
    if sensor == None:
        return {"changed": False, "msg": "motion detector not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get current time
    res_time = ctx.run(["date", "+%H %M"], mutates=False)
    hour = 0
    minute = 0
    if res_time.rc == 0 and res_time.stdout:
        parts = res_time.stdout.strip().split()
        if len(parts) == 2:
            if parts[0].isdigit() and parts[1].isdigit():
                hour = int(parts[0])
                minute = int(parts[1])

    today_minutes = hour * 60 + minute

    # Determine active time period
    time_periods = params.get("time_periods")
    if time_periods != None and type(time_periods) == "dict":
        res_day = ctx.run(["date", "+%u"], mutates=False)
        day_num = 0
        if res_day.rc == 0 and res_day.stdout.strip().isdigit():
            day_num = int(res_day.stdout.strip()) - 1
            if day_num < 0 or day_num > 6:
                day_num = 0
        periods = time_periods.get(_WEEKDAYS[day_num], [((0, 0), (24, 0))])
    else:
        periods = [((0, 0), (24, 0))]

    in_period = False
    for per in periods:
        if type(per) != "list" or len(per) != 2:
            continue
        start = per[0]
        end = per[1]
        if type(start) != "list" or len(start) != 2:
            continue
        if type(end) != "list" or len(end) != 2:
            continue
        start_h = start[0]
        start_m = start[1]
        end_h = end[0]
        end_m = end[1]
        if type(start_h) == "int" and type(start_m) == "int" and type(end_h) == "int" and type(end_m) == "int":
            per_low = start_h * 60 + start_m
            per_high = end_h * 60 + end_m
            if per_low <= today_minutes and today_minutes < per_high:
                in_period = True
                break

    value = sensor.get("value", 0)
    maximum = sensor.get("maximum", 100)

    if value >= maximum:
        state = "WARN" if in_period else "OK"
    else:
        state = "OK"

    return {"changed": False, "msg": "Motion detected" if value >= maximum else "No motion detected",
            "data": {"state": state, "metrics": {"motion": value}, "details": ""}}