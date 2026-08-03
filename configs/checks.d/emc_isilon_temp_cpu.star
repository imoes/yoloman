def main(ctx, params):
    if params.get("_discover"):
        return _discovery(ctx, params)
    return _check(ctx, params)


def _isilon_temp_item_name(sensor_name):
    if "CPU Throttle" in sensor_name:
        return sensor_name.split("(", 1)[1].split(")", 1)[0]
    return sensor_name[5:]


def _to_float(s):
    s = s.strip()
    if s.startswith("STRING:"):
        s = s[7:].strip().strip('"')
    if s.startswith("INTEGER:"):
        s = s[8:].strip()
    if not s:
        return None
    sign = 1.0
    body = s
    if body.startswith("+"):
        body = body[1:]
    elif body.startswith("-"):
        sign = -1.0
        body = body[1:]
    if not body:
        return None
    parts = body.split(".", 1)
    if len(parts) == 1:
        int_part = parts[0]
        frac_part = ""
    else:
        int_part = parts[0]
        frac_part = parts[1]
    int_ok = int_part == "" or _is_digits(int_part)
    frac_ok = frac_part == "" or _is_digits(frac_part)
    if not (int_ok and frac_ok):
        return None
    if int_part == "" and frac_part == "":
        return None
    iv = _int_of(int_part) if int_part != "" else 0
    fv = _frac_of(frac_part) if frac_part != "" else 0.0
    return sign * (float(iv) + fv)


def _is_digits(s):
    if not s:
        return False
    for ch in s:
        if ch < "0" or ch > "9":
            return False
    return True


def _int_of(s):
    v = 0
    for ch in s:
        v = v * 10 + (ord(ch) - ord("0"))
    return v


def _frac_of(s):
    v = 0.0
    scale = 0.1
    for ch in s:
        v = v + (ord(ch) - ord("0")) * scale
        scale = scale * 0.1
    return v


def _fetch_sensors(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    descr = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if descr.rc != 0:
        return None, "snmp get sysDescr failed: " + descr.stderr
    if "isilon" not in descr.stdout.lower():
        return None, "not an Isilon device (sysDescr does not contain 'isilon')"

    name_base = ".1.3.6.1.4.1.12124.2.54.1.3"
    walk = ctx.run(
        ["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, name_base],
        mutates=False,
    )
    if walk.rc != 0:
        return None, "snmp walk sensor names failed: " + walk.stderr

    sensors = []
    for line in walk.stdout.splitlines():
        idx = line.find(" ")
        if idx < 0:
            continue
        oid = line[:idx]
        name = line[idx + 1:]
        suffix = oid[len(name_base) + 1:]
        if not suffix:
            continue

        val_oid = ".1.3.6.1.4.1.12124.2.54.1.4." + suffix
        vres = ctx.run(
            ["snmpget", "-v" + version, "-c", community, "-Oqv", host, val_oid],
            mutates=False,
        )
        if vres.rc != 0:
            continue
        fval = _to_float(vres.stdout.strip())
        if fval == None:
            continue
        sensors.append((name, fval))

    return sensors, ""


def _discovery(ctx, params):
    sensors, err = _fetch_sensors(ctx, params)
    if err != "":
        return {"changed": False, "msg": "discovery error: " + err,
                "data": {"discovery": []}}
    discovery = []
    for sensor_name, _value in sensors:
        if "CPU Throttle" in sensor_name:
            item_name = sensor_name.split("(", 1)[1].split(")", 1)[0]
            discovery.append({
                "item": item_name,
                "params": {"levels": [75.0, 85.0]},
                "metrics": ["temperature"],
            })
    return {"changed": False,
            "msg": "discovered %d cpu temperature sensors" % len(discovery),
            "data": {"discovery": discovery}}


def _check(ctx, params):
    item = params.get("item", "")
    sensors, err = _fetch_sensors(ctx, params)
    if err != "":
        return {"changed": False, "msg": err,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    for sensor_name, value in sensors:
        if item == _isilon_temp_item_name(sensor_name):
            levels = params.get("levels", [75.0, 85.0])
            warn = levels[0]
            crit = levels[1]
            state = "CRIT" if value >= crit else ("WARN" if value >= warn else "OK")
            return {"changed": False,
                    "msg": "%s: %f C" % (item, value),
                    "data": {"state": state,
                             "metrics": {"temperature": value},
                             "details": "sensor=%s" % sensor_name}}
    return {"changed": False, "msg": "no cpu temperature sensor found for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}