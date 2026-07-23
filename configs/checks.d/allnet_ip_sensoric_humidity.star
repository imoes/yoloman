def _get_tag(block, tag):
    open_tag = "<" + tag + ">"
    close_tag = "</" + tag + ">"
    start = block.find(open_tag)
    if start == -1:
        return None
    start = start + len(open_tag)
    end = block.find(close_tag, start)
    if end == -1:
        return None
    return block[start:end].strip()

def _get_sensor_block(xml, sensor_id):
    open_tag = "<" + sensor_id + ">"
    close_tag = "</" + sensor_id + ">"
    start = xml.find(open_tag)
    if start == -1:
        return None
    inner_start = start + len(open_tag)
    end = xml.find(close_tag, inner_start)
    if end == -1:
        return None
    return xml[inner_start:end]

def _safe_float(s):
    if s == None:
        return None
    s = s.strip()
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    dot = s.find(".")
    if dot == -1:
        if not s.isdigit():
            return None
        v = float(int(s))
        return -v if neg else v
    int_part = s[:dot]
    dec_part = s[dot + 1:]
    if not int_part.isdigit() or not dec_part.isdigit():
        return None
    denom = 1
    for _ in range(len(dec_part)):
        denom = denom * 10
    v = float(int(int_part)) + float(int(dec_part)) / float(denom)
    return -v if neg else v

def _parse_sensors(xml):
    sensors = {}
    for n in range(1, 32):
        sid = "sensor" + str(n)
        block = _get_sensor_block(xml, sid)
        if block == None:
            continue
        sensor = {}
        nm = _get_tag(block, "name")
        if nm != None:
            sensor["name"] = nm
        unit = _get_tag(block, "unit")
        if unit != None:
            sensor["unit"] = unit
        func = _get_tag(block, "function")
        if func != None:
            sensor["function"] = func
        vf = _get_tag(block, "value_float")
        if vf != None:
            sensor["value_float"] = vf
        sensors[sid] = sensor
    return sensors

def _compose_item(sensor_id, sensor):
    num = sensor_id.replace("sensor", "")
    if "name" in sensor:
        return sensor["name"] + " Sensor " + num
    return "Sensor " + num

def _is_humidity(sensor_data):
    return sensor_data.get("function") == "2" or sensor_data.get("unit") == "%"

def _sensor_num_from_item(item):
    parts = item.rsplit(" ", 1)
    return parts[-1] if len(parts) > 1 else item

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 80)
    url = "http://" + host + ":" + str(port) + "/xml"

    res = ctx.run(["curl", "-s", "--max-time", "10", url], mutates=False)
    if res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "cannot reach device",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "cannot reach device: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    xml = res.stdout
    sensors = _parse_sensors(xml)

    if params.get("_discover"):
        out = []
        for sid, sdata in sensors.items():
            if _is_humidity(sdata):
                item = _compose_item(sid, sdata)
                out.append({
                    "item": item,
                    "params": {
                        "warn": 60.0, "crit": 65.0,
                        "warn_lower": 40.0, "crit_lower": 35.0,
                    },
                    "metrics": ["humidity"],
                })
        return {"changed": False,
                "msg": "discovered %d humidity sensors" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    num = _sensor_num_from_item(item)
    sid = "sensor" + num

    if sid not in sensors:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sdata = sensors[sid]
    value = _safe_float(sdata.get("value_float"))

    if value == None:
        return {"changed": False, "msg": "no valid value for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("warn", 60.0)
    crit = params.get("crit", 65.0)
    warn_lower = params.get("warn_lower", 40.0)
    crit_lower = params.get("crit_lower", 35.0)

    if value >= crit:
        state = "CRIT"
        detail = "humidity too high (>= %f%%)" % crit
    elif value >= warn:
        state = "WARN"
        detail = "humidity high (>= %f%%)" % warn
    elif value <= crit_lower:
        state = "CRIT"
        detail = "humidity too low (<= %f%%)" % crit_lower
    elif value <= warn_lower:
        state = "WARN"
        detail = "humidity low (<= %f%%)" % warn_lower
    else:
        state = "OK"
        detail = ""

    msg = "Humidity: %f%%" % value
    if state != "OK":
        msg = msg + " (%s)" % detail

    return {"changed": False,
            "msg": msg,
            "data": {
                "state": state,
                "metrics": {"humidity": value},
                "details": detail,
            }}