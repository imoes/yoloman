def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    base = ".1.3.6.1.4.1.2254.2.4.7"

    def detect_modulys():
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-OQ",
                       host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return False
        val = res.stdout.strip()
        return val.endswith(".1.3.6.1.4.1.2254.2.4") or val == ".1.3.6.1.4.1.2254.2.4"

    if params.get("_discover"):
        if not detect_modulys():
            return {"changed": False, "msg": "not a Modulys UPS (OID mismatch / not installed)",
                    "data": {"discovery": []}}

        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-OQ",
                       host, base + ".1", base + ".4", base + ".5",
                       base + ".8", base + ".9"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch battery OIDs",
                    "data": {"discovery": []}}

        vals = res.stdout.strip().split("\n")
        if len(vals) < 5:
            return {"changed": False, "msg": "incomplete battery data",
                    "data": {"discovery": []}}

        capacity_default = (95, 90)
        battime_default = (0, 0)
        return {"changed": False, "msg": "discovered battery service",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"capacity": capacity_default, "battime": battime_default},
                     "metrics": ["capacity", "health", "uptime", "battime", "temperature"]},
                    {"item": "Battery",
                     "params": {},
                     "metrics": ["temperature"]},
                ]}}

    if not detect_modulys():
        return {"changed": False,
                "msg": "no Modulys UPS detected (sysObjectID mismatch)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item == "Battery":
        temp_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-OQ",
                            host, base + ".9"], mutates=False)
        if temp_res.rc != 0 or not temp_res.stdout.strip():
            return {"changed": False,
                    "msg": "no battery temperature reported",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        temp_str = temp_res.stdout.strip()
        if not temp_str.replace(".", "", 1).isdigit():
            return {"changed": False,
                    "msg": "invalid temperature value: " + temp_str,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        temp = float(temp_str)
        crit = params.get("crit", 60)
        warn = params.get("warn", 50)

        state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
        return {"changed": False,
                "msg": "Battery Temperature %s C" % str(temp),
                "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}

    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-OQ",
                   host, base + ".1", base + ".4", base + ".5",
                   base + ".8", base + ".9"], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "failed to fetch battery information: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.strip().split("\n")
    if len(lines) < 5:
        return {"changed": False,
                "msg": "incomplete battery data: got %d values" % len(lines),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    health = int(lines[0])
    uptime = int(lines[1])
    remaining_time_raw = lines[2]
    capacity = int(lines[3])
    temperature_str = lines[4].strip()

    if uptime == 0:
        remaining_time = float(sys_maxsize())
    else:
        remaining_time = float(remaining_time_raw) if remaining_time_raw else float(sys_maxsize())

    if not temperature_str or temperature_str == "NOSUCHOBJECT" or temperature_str == "NOSUCHINSTANCE":
        temperature = None
    else:
        temperature = float(temperature_str)

    capacity_params = params.get("capacity", (95, 90))
    battime_params = params.get("battime", (0, 0))
    cap_warn, cap_crit = capacity_params
    bt_warn, bt_crit = battime_params

    state = "OK"
    summaries = []

    if uptime == 0:
        summaries.append("On mains")
    else:
        summaries.append("Discharging for %d minutes" % (uptime // 60))

    if health == 1:
        state = "WARN" if state != "CRIT" else state
        summaries.append("Battery health weak")
    elif health == 2:
        state = "CRIT"
        summaries.append("Battery needs to be replaced")

    if capacity <= cap_crit:
        state = "CRIT"
    elif capacity <= cap_warn:
        state = "WARN" if state != "CRIT" else state
    summaries.append("Battery capacity at %s%%" % str(capacity))

    if uptime == 0:
        remaining_time_for_check = float(sys_maxsize())
    else:
        remaining_time_for_check = remaining_time

    if remaining_time_for_check <= bt_crit:
        state = "CRIT"
    elif remaining_time_for_check <= bt_warn:
        state = "WARN" if state != "CRIT" else state
    summaries.append("Minutes remaining %s" % format_remaining(remaining_time))

    metrics = {"capacity": capacity, "health": health, "uptime": uptime,
               "battime": remaining_time}
    if temperature != None:
        metrics["temperature"] = temperature
        summaries.append("Temperature %s C" % str(temperature))

    return {"changed": False,
            "msg": "; ".join(summaries),
            "data": {"state": state, "metrics": metrics, "details": ""}}


def sys_maxsize():
    return 9223372036854775807


def format_remaining(minutes_float):
    if minutes_float == float(sys_maxsize()):
        return "unlimited"
    minutes_int = int(minutes_float)
    if minutes_int >= 60:
        hours = minutes_int // 60
        mins = minutes_int % 60
        return "%dh %dm" % (hours, mins)
    return "%dm" % minutes_int