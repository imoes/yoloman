def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["hp_msacli", "show", "summary"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout) if res.stdout else {}
        psus = data.get("power-supplies", [])
        out = []
        for psu in psus:
            name = psu.get("name", "")
            voltages = 0
            if psu.get("dc12v", "0") != "0":
                voltages += 1
            if psu.get("dc5v", "0") != "0":
                voltages += 1
            if psu.get("dc33v", "0") != "0":
                voltages += 1
            if voltages > 0:
                out.append({"item": psu.get("durable-id", name),
                            "params": {},
                            "metrics": ["voltage", "temperature"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["hp_msacli", "show", "summary"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "HP MSA CLI not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout) if res.stdout else {}
    psus = data.get("power-supplies", [])
    target = None
    for psu in psus:
        if psu.get("durable-id", "") == item:
            target = psu
            break
    if target == None:
        return {"changed": False, "msg": "PSU %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    indicators = ("dc12v", "dc5v", "dc33v")
    val_count = 0
    for i in indicators:
        if target.get(i, "0") != "0":
            val_count += 1
    if val_count == 0:
        return {"changed": False, "msg": "PSU %s has no valid voltage data" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    v12_lower = params.get("levels_12v_lower", (11.9, 11.8))
    v12_upper = params.get("levels_12v_upper", (12.1, 12.2))
    v5_lower = params.get("levels_5v_lower", (4.9, 4.8))
    v5_upper = params.get("levels_5v_upper", (5.1, 5.2))
    v3_lower = params.get("levels_33v_lower", (3.25, 3.20))
    v3_upper = params.get("levels_33v_upper", (3.4, 3.45))
    temp_levels = params.get("levels", (40.0, 45.0))
    temp_warn = temp_levels[0]
    temp_crit = temp_levels[1]
    
    metrics = {}
    msg_parts = []
    state = "OK"
    details = ""
    
    psu_configs = [
        ("dc12v", "12 V", v12_lower, v12_upper),
        ("dc5v", "5 V", v5_lower, v5_upper),
        ("dc33v", "3.3 V", v3_lower, v3_upper),
    ]
    for config in psu_configs:
        psu_type = config[0]
        psu_type_readable = config[1]
        lower = config[2]
        upper = config[3]
        raw = target.get(psu_type, "0")
        if raw == "0" or raw == "":
            continue
        voltage = float(raw) / 100.0
        metrics[psu_type] = voltage
        warn_low = lower[0]
        crit_low = lower[1]
        warn_high = upper[0]
        crit_high = upper[1]
        psu_state = "OK"
        if voltage <= crit_low or voltage >= crit_high:
            psu_state = "CRIT"
        elif voltage <= warn_low or voltage >= warn_high:
            psu_state = "WARN"
        if state == "OK" and psu_state == "WARN":
            state = "WARN"
        if psu_state == "CRIT":
            state = "CRIT"
        msg_parts.append("%s: %f V (%s)" % (psu_type_readable, voltage, psu_state))
    
    raw_temp = target.get("dctemp", "0")
    if raw_temp != "0" and raw_temp != "":
        temperature = float(raw_temp)
        metrics["temperature"] = temperature
        temp_state = "OK"
        if temperature >= temp_crit:
            temp_state = "CRIT"
        elif temperature >= temp_warn:
            temp_state = "WARN"
        if state == "OK" and temp_state == "WARN":
            state = "WARN"
        if temp_state == "CRIT":
            state = "CRIT"
        msg_parts.append("Temp: %f C (%s)" % (temperature, temp_state))
    
    health = target.get("health", "unknown")
    status = target.get("status", "unknown")
    details = "PSU: %s\nHealth: %s\nStatus: %s\nVoltages:" % (
        target.get("name", ""), health, status)
    for config in psu_configs:
        psu_type = config[0]
        psu_type_readable = config[1]
        raw = target.get(psu_type, "0")
        if raw != "0" and raw != "":
            details += "\n  %s: %f V" % (psu_type_readable, float(raw) / 100.0)
    if raw_temp != "0" and raw_temp != "":
        details += "\n  Temperature: %f C" % float(raw_temp)
    
    msg = "%s: %s" % (item, ", ".join(msg_parts)) if msg_parts else "PSU %s" % item
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}