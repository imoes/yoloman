def main(ctx, params):
    if params.get("_discover"):
        sysoid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                         mutates=False)
        if sysoid.rc != 0 or ".1.3.6.1.4.1.2606.1" not in (sysoid.stdout or ""):
            if sysoid.rc == 127:
                return {"changed": False, "msg": "snmpget not installed",
                        "data": {"discovery": [], "host_labels": {}}}
            return {"changed": False, "msg": "not a Rittal CMC device",
                    "data": {"discovery": [], "host_labels": {}}}

        temps = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-Oqn", params.get("host", "localhost"),
                         ".1.3.6.1.4.1.2606.1.1.1", ".1.3.6.1.4.1.2606.1.1.2"],
                        mutates=False)
        if temps.rc != 0:
            return {"changed": False, "msg": "failed to fetch current temperatures",
                    "data": {"discovery": [], "host_labels": {}}}

        levels = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-Oqv", params.get("host", "localhost"),
                          ".1.3.6.1.4.1.2606.1.4.4", ".1.3.6.1.4.1.2606.1.4.5",
                          ".1.3.6.1.4.1.2606.1.4.6", ".1.3.6.1.4.1.2606.1.4.7"],
                         mutates=False)

        out = []
        for item in ["1", "2"]:
            metrics = ["temperature"]
            out.append({"item": item, "params": {"levels": (45.0, 50.0)}, "metrics": metrics})
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(out),
                "data": {"discovery": out, "host_labels": {"cmk/os_family": "linux"}}}

    item = params.get("item", "")
    if item not in ["1", "2"]:
        return {"changed": False, "msg": "invalid sensor item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    offset = int(item) - 1

    temps = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                     "-Oqn", params.get("host", "localhost"),
                     ".1.3.6.1.4.1.2606.1.1.1", ".1.3.6.1.4.1.2606.1.1.2"],
                    mutates=False)
    if temps.rc != 0:
        return {"changed": False, "msg": "failed to fetch current temperatures",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_vals = {}
    for line in temps.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            oid = parts[0]
            val = parts[1].strip().strip('"')
            temp_vals[oid] = val

    col_oid = ".1.3.6.1.4.1.2606.1.1.%d" % int(item)
    if col_oid not in temp_vals:
        return {"changed": False, "msg": "no temperature value for sensor %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    current_temp = int(temp_vals[col_oid])

    levels = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                      "-Oqv", params.get("host", "localhost"),
                      ".1.3.6.1.4.1.2606.1.4.4", ".1.3.6.1.4.1.2606.1.4.5",
                      ".1.3.6.1.4.1.2606.1.4.6", ".1.3.6.1.4.1.2606.1.4.7"],
                     mutates=False)
    if levels.rc != 0:
        return {"changed": False, "msg": "failed to fetch device levels",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    level_vals = levels.stdout.splitlines()
    if len(level_vals) < 4:
        return {"changed": False, "msg": "incomplete device level data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    dev_high = int(level_vals[offset * 2].strip().strip('"'))
    dev_low = int(level_vals[offset * 2 + 1].strip().strip('"'))

    warn, crit = params.get("levels", (45.0, 50.0))
    if type(warn) == "list":
        warn = warn[0]
        crit = warn[1] if len(warn) > 1 else crit

    state = "OK"
    if current_temp >= crit or (dev_high > 0 and current_temp >= dev_high):
        state = "CRIT"
    elif current_temp >= warn or (dev_high > 0 and current_temp >= dev_high):
        state = "WARN"

    state_lower = "OK"
    if current_temp <= dev_low:
        state_lower = "CRIT"

    if state == "CRIT" or state_lower == "CRIT":
        final_state = "CRIT"
    elif state == "WARN" or state_lower == "WARN":
        final_state = "WARN"
    else:
        final_state = "OK"

    details = "Sensor %s: %dC (device high: %dC, device low: %dC)" % (
        item, current_temp, dev_high, dev_low)

    metrics = {"temperature": current_temp}
    if dev_high > 0:
        metrics["dev_high"] = dev_high
    if dev_low > 0:
        metrics["dev_low"] = dev_low

    return {"changed": False, "msg": details,
            "data": {"state": final_state, "metrics": metrics, "details": details}}