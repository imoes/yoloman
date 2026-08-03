def _pow10(exp):
    if exp == 0:
        return 1.0
    if exp > 0:
        result = 1.0
        for _ in range(exp):
            result = result * 10.0
        return result
    result = 1.0
    n = 0 - exp
    for _ in range(n):
        result = result * 10.0
    return 1.0 / result

SYS_OID = ".1.3.6.1.4.1.31770.2.1"
VAR_BASE = ".1.3.6.1.4.1.31770.2.2.8"
VAR_TYPE = "2.1.6"
VAR_STATUS = "2.1.7"
VAR_SCALING = "2.1.9"
VAR_DATA = "4.1.5"
SENSOR_TYPES = {"256": "temp", "257": "humidity"}
STATUS_MAP = {
    "0": (0, "expected"), "1": (3, "undefined"), "2": (0, "OK"),
    "3": (2, "error high"), "4": (2, "error low"),
    "5": (1, "warning high"), "6": (1, "warning low"),
    "7": (2, "lost"), "8": (1, "deactivate"),
    "9": (2, "on alarm identidy"), "10": (2, "off alarm identify"),
    "11": (2, "on alarm"), "12": (2, "off alarm"),
    "13": (1, "on warning identify"), "14": (1, "off warning identify"),
    "15": (1, "on warning"), "16": (1, "off warning"),
    "17": (0, "on identify"), "18": (0, "off identify"),
    "19": (0, "on"), "20": (1, "off"),
    "21": (2, "on child alarm"), "22": (2, "off child alarm"),
    "23": (1, "on child warning"), "24": (1, "off child warning"),
    "25": (2, "child alarm"), "26": (1, "child warning"),
    "27": (2, "lost child"), "36": (1, "update in progress"),
    "37": (2, "update error"), "38": (1, "ongoing switch"),
    "39": (2, "high"), "40": (1, "low"),
    "41": (2, "alarm"), "42": (1, "warning"),
    "43": (0, "ok"), "44": (1, "disabled"),
    "45": (1, "fw version too new"),
}

def _parse_walk_col(res, col_oid):
    rows = {}
    if not res.stdout:
        return rows
    for line in res.stdout.split("\n"):
        s = line.strip()
        if not s:
            continue
        sp = s.find(" ")
        if sp < 0:
            continue
        oid = s[:sp]
        val = s[sp + 1:]
        if oid.startswith(col_oid + "."):
            idx = oid[len(col_oid) + 1:]
            if idx:
                rows[idx] = val
    return rows

def _sensor_name(pdu, ch1, ch2):
    name = "Master"
    if pdu != "0":
        name = "PDU %s" % pdu
    return "Sensor %s %s/%s" % (name, ch1, ch2)

def _detect_bluenet2(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    return res.stdout.find(SYS_OID) >= 0

def _read_sensor_table(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    res_type = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                        host, VAR_BASE + "." + VAR_TYPE], mutates=False)
    res_status = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                          host, VAR_BASE + "." + VAR_STATUS], mutates=False)
    res_scale = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                         host, VAR_BASE + "." + VAR_SCALING], mutates=False)
    res_data = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                        host, VAR_BASE + "." + VAR_DATA], mutates=False)

    if res_type.rc != 0:
        return None

    types = _parse_walk_col(res_type, VAR_BASE + "." + VAR_TYPE)
    statuses = _parse_walk_col(res_status, VAR_BASE + "." + VAR_STATUS)
    scalings = _parse_walk_col(res_scale, VAR_BASE + "." + VAR_SCALING)
    datas = _parse_walk_col(res_data, VAR_BASE + "." + VAR_DATA)

    sensors = {"temp": {}, "humidity": {}}

    for idx, ty in types.items():
        bucket = SENSOR_TYPES.get(ty)
        if bucket != "humidity":
            continue
        parts = idx.split(".")
        if len(parts) < 5:
            continue
        pdu = parts[0]
        ch1 = parts[3]
        ch2 = parts[4]
        name = _sensor_name(pdu, ch1, ch2)

        status_val = statuses.get(idx, "2")
        state_info = STATUS_MAP.get(status_val, (3, "unknown"))
        scale_val = scalings.get(idx, "0")
        data_val = datas.get(idx, "0")

        reading = float(data_val) * _pow10(int(scale_val))
        sensors["humidity"][name] = (reading, state_info)

    return {"sensors": sensors}

def main(ctx, params):
    if not _detect_bluenet2(ctx, params):
        return {"changed": False, "msg": "BACHMANN bluenet2 device not found",
                "data": {"discovery": []}}

    section = _read_sensor_table(ctx, params)

    if params.get("_discover"):
        if section == None or len(section["sensors"]["humidity"]) == 0:
            return {"changed": False,
                    "msg": "no bluenet2 humidity sensors found",
                    "data": {"discovery": []}}
        discovery = []
        for item in section["sensors"]["humidity"]:
            discovery.append({"item": item,
                              "params": {},
                              "metrics": ["humidity"]})
        return {"changed": False,
                "msg": "discovered %d humidity sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    hum = section["sensors"]["humidity"] if section != None else {}
    if not hum.get(item):
        return {"changed": False, "msg": "humidity sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading, (state, state_readable) = hum[item]
    lvls = params.get("levels", ["75.0", "80.0"])
    if type(lvls) == "list" and len(lvls) >= 2:
        warn = float(lvls[0])
        crit = float(lvls[1])
    else:
        warn = 75.0
        crit = 80.0
    lcl = params.get("levels_lower", ["5.0", "8.0"])
    if type(lcl) == "list" and len(lcl) >= 2:
        warn_l = float(lcl[0])
        crit_l = float(lcl[1])
    else:
        warn_l = 5.0
        crit_l = 8.0

    if state != 0:
        cmk_state = "CRIT" if state >= 2 else ("WARN" if state >= 1 else "OK")
    else:
        if reading >= crit:
            cmk_state = "CRIT"
        elif reading >= warn:
            cmk_state = "WARN"
        elif reading <= crit_l:
            cmk_state = "CRIT"
        elif reading <= warn_l:
            cmk_state = "WARN"
        else:
            cmk_state = "OK"

    return {"changed": False,
            "msg": "%s: %f%%, %s" % (item, reading, state_readable),
            "data": {"state": cmk_state,
                     "metrics": {"humidity": reading},
                     "details": state_readable}}