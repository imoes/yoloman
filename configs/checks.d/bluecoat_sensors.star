def _fmt_v(x):
    return "%f" % x

def _is_num(s):
    if s == None or len(s) == 0:
        return False
    i = 0
    if s[0] == "-" or s[0] == "+":
        i = 1
        if len(s) == 1:
            return False
    dot = False
    hasd = False
    for j in range(i, len(s)):
        c = s[j]
        if c == ".":
            if dot:
                return False
            dot = True
        else:
            code = ord(c)
            if code >= 48 and code <= 57:
                hasd = True
            else:
                return False
    return hasd

def _to_float(s):
    if not _is_num(s):
        return None
    neg = False
    st = s
    if st[0] == "-":
        neg = True
        st = st[1:]
    elif st[0] == "+":
        st = st[1:]
    ip = ""
    frac = ""
    after = False
    for c in st:
        if c == ".":
            after = True
        elif after:
            frac = frac + c
        else:
            ip = ip + c
    v = 0
    if ip == "":
        ip = "0"
    for c in ip:
        v = v * 10 + (ord(c) - 48)
    fracv = 0
    fl = 0
    for c in frac:
        fracv = fracv * 10 + (ord(c) - 48)
        fl = fl + 1
    f = float(fracv)
    k = 1
    for _ in range(0, fl):
        k = k * 10
    result = v + f / k
    if neg:
        result = -result
    return result

def _pow10(e):
    r = 1.0
    i = 0
    while i < e:
        r = r * 10.0
        i = i + 1
    return r

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base = ".1.3.6.1.4.1.3417.2.1.1.1.1.1"
    detect_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", host,
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if detect_res.rc == 127:
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "snmp not available"}}
    if detect_res.rc != 0:
        return {"changed": False, "msg": "detection failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if detect_res.stdout.find("1.3.6.1.4.1.3417.1.1") == -1:
        return {"changed": False, "msg": "not a bluecoat device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cols = ["9", "5", "7", "4", "3"]
    col_oids = [base + "." + c for c in cols]

    table = {}
    for ci in range(0, len(col_oids)):
        wres = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oids[ci]],
            mutates=False,
        )
        if wres.rc != 0:
            return {"changed": False, "msg": "walk failed for " + col_oids[ci],
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        for line in wres.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip()
            idx = oid[len(col_oids[ci]) + 1:]
            if idx not in table:
                table[idx] = [None, None, None, None, None]
            table[idx][ci] = val

    temperature_sensors = {}
    other_sensors = {}
    for idx in sorted(table.keys()):
        row = table[idx]
        if len(row) < 5 or row[0] == None or row[1] == None or row[2] == None or row[3] == None or row[4] == None:
            continue
        name = row[0]
        reading = row[1]
        status = row[2]
        scale = row[3]
        unit = row[4]
        sensor_name = name.replace(" temperature", "")
        rv = _to_float(reading)
        if rv == None:
            continue
        sv = _to_float(scale)
        if sv == None:
            continue
        if sv == 0:
            value = rv
        elif sv > 0:
            value = rv * _pow10(int(sv))
        else:
            value = rv / _pow10(int(-sv))
        is_ok = (status == "1")

        if unit == "5":
            temperature_sensors[sensor_name] = {"value": value, "is_ok": is_ok}
        else:
            other_sensors[sensor_name] = {"value": value, "is_ok": is_ok,
                                          "type": "voltage" if unit == "4" else "other"}

    if params.get("_discover"):
        plugin = params.get("plugin", "")
        if plugin == "bluecoat_sensors_temp":
            td = []
            for sensor_name in sorted(temperature_sensors.keys()):
                td.append({
                    "item": sensor_name,
                    "params": {"levels": (params.get("temp_warn", 60), params.get("temp_crit", 80))},
                    "metrics": ["temperature"],
                })
            return {"changed": False,
                    "msg": "discovered %d items" % len(td),
                    "data": {"discovery": td}}
        discovery = []
        for sensor_name in sorted(other_sensors.keys()):
            mt = []
            if other_sensors[sensor_name]["type"] == "voltage":
                mt = ["voltage"]
            discovery.append({
                "item": sensor_name,
                "params": {},
                "metrics": mt,
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    plugin = params.get("plugin", "")
    if plugin == "bluecoat_sensors_temp":
        item = params.get("item", "")
        sensor = temperature_sensors.get(item)
        if sensor == None:
            return {"changed": False, "msg": "no such sensor: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        warn = params.get("warn", 60)
        crit = params.get("crit", 80)
        val = sensor["value"]
        if val >= crit:
            state = "CRIT"
        elif val >= warn:
            state = "WARN"
        else:
            state = "OK"
        return {"changed": False, "msg": "%s" % _fmt_v(val),
                "data": {"state": state, "metrics": {"temperature": val}, "details": ""}}

    item = params.get("item", "")
    sensor = other_sensors.get(item)
    if sensor == None:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if sensor["is_ok"]:
        state = "OK"
    else:
        state = "CRIT"
    val = _fmt_v(sensor["value"])
    metrics = {}
    if sensor["type"] == "voltage":
        summary = val + " V"
        metrics = {"voltage": sensor["value"]}
    else:
        summary = val
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}