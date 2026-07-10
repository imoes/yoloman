def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["check_mk_agent", "--section", "adva_fsp_temp"], mutates=False)
        raw = res.stdout.strip()
        lines = raw.splitlines() if raw else []
        discovered = []
        for line in lines:
            parts = line.split()
            if len(parts) < 5:
                continue
            raw_temp_str = parts[0]
            raw_high_str = parts[1]
            raw_low_str = parts[2]
            description = parts[3]
            name = parts[4]
            # Validate numeric strings
            is_valid = True
            for s in [raw_temp_str, raw_high_str, raw_low_str]:
                if s.strip() == "" or (s.find(".") != -1 and not s.replace(".", "", 1).lstrip("-").isdigit()) or (s.find(".") == -1 and not s.lstrip("-").isdigit()):
                    is_valid = False
                    break
            if not is_valid:
                continue
            raw_temp = float(raw_temp_str)
            raw_high = float(raw_high_str)
            raw_low = float(raw_low_str)
            if not description or not bool(raw_temp):
                continue
            temp = raw_temp / 10.0
            if temp > -273.0:
                discovered.append({
                    "item": name,
                    "params": {},
                    "metrics": ["temperature"]
                })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovered),
            "data": {"discovery": discovered}
        }

    item = params.get("item", "")
    res = ctx.run(["check_mk_agent", "--section", "adva_fsp_temp"], mutates=False)
    raw = res.stdout.strip()
    lines = raw.splitlines() if raw else []

    sensor = None
    for line in lines:
        parts = line.split()
        if len(parts) < 5:
            continue
        raw_temp_str = parts[0]
        raw_high_str = parts[1]
        raw_low_str = parts[2]
        description = parts[3]
        name = parts[4]
        # Validate numeric strings
        is_valid = True
        for s in [raw_temp_str, raw_high_str, raw_low_str]:
            if s.strip() == "" or (s.find(".") != -1 and not s.replace(".", "", 1).lstrip("-").isdigit()) or (s.find(".") == -1 and not s.lstrip("-").isdigit()):
                is_valid = False
                break
        if not is_valid:
            continue
        raw_temp = float(raw_temp_str)
        raw_high = float(raw_high_str)
        raw_low = float(raw_low_str)
        if name == item:
            if not description or not bool(raw_temp):
                continue
            temp = raw_temp / 10.0
            if temp <= -273.0:
                return {
                    "changed": False,
                    "msg": "Invalid sensor data",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            sensor = {"temperature": temp,
                      "threshold_high": raw_high / 10.0,
                      "threshold_low": raw_low / 10.0}
            break

    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    temp = sensor["temperature"]
    warn = params.get("warn", None)
    crit = params.get("crit", None)
    warn_lower = params.get("warn_lower", None)
    crit_lower = params.get("crit_lower", None)

    dev_warn_upper = sensor["threshold_high"]
    dev_crit_upper = sensor["threshold_high"]
    dev_warn_lower = None
    dev_crit_lower = None
    if sensor["threshold_low"] > -273.0:
        dev_warn_lower = sensor["threshold_low"]
        dev_crit_lower = sensor["threshold_low"]

    state = "OK"
    summary_parts = []

    if crit != None and temp >= crit:
        state = "CRIT"
        summary_parts.append("Critical (threshold: %s)" % crit)
    elif warn != None and temp >= warn:
        state = "WARN"
        summary_parts.append("Warning (threshold: %s)" % warn)

    if crit_lower != None and temp <= crit_lower:
        state = "CRIT"
        summary_parts.append("Critical lower (threshold: %s)" % crit_lower)
    elif warn_lower != None and temp <= warn_lower:
        state = "WARN"
        summary_parts.append("Warning lower (threshold: %s)" % warn_lower)

    if state == "OK":
        if dev_crit_upper != None and temp >= dev_crit_upper:
            state = "CRIT"
            summary_parts.append("Deviation high critical (threshold: %s)" % dev_crit_upper)
        elif dev_warn_upper != None and temp >= dev_warn_upper:
            state = "WARN"
            summary_parts.append("Deviation high warning (threshold: %s)" % dev_warn_upper)
        elif dev_crit_lower != None and temp <= dev_crit_lower:
            state = "CRIT"
            summary_parts.append("Deviation low critical (threshold: %s)" % dev_crit_lower)
        elif dev_warn_lower != None and temp <= dev_warn_lower:
            state = "WARN"
            summary_parts.append("Deviation low warning (threshold: %s)" % dev_warn_lower)

    if state == "OK":
        summary_parts.append("Temperature normal")

    summary_parts.insert(0, "Temperature: %.1f C" % temp)
    msg = ", ".join(summary_parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }
