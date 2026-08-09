_OID_PARSE = {
    "1": "Room",
    "2": "Outdoor",
    "3": "Delivery",
    "4": "Cold Water",
    "5": "Hot Water",
    "7": "Cold Water Outlet",
    "10": "Circuit 1 Suction",
    "11": "Circuit 2 Suction",
    "12": "Circuit 1 Evap",
    "13": "Circuit 2 Evap",
    "14": "Circuit 1 Superheat",
    "15": "Circuit 2 Superheat",
    "20": "Cooling Set Point",
    "21": "Cooling Prop. Band",
    "22": "Cooling 2nd Set Point",
    "23": "Heating Set Point",
    "24": "Heating 2nd Set Point",
    "25": "Heating Prop. Band",
}

_DEFAULT_LEVELS = {
    "Room": (30, 35),
    "Outdoor": (60, 70),
    "Delivery": (60, 70),
    "Cold Water": (60, 70),
    "Hot Water": (60, 70),
    "Cold Water Outlet": (60, 70),
    "Circuit 1 Suction": (60, 70),
    "Circuit 2 Suction": (60, 70),
    "Circuit 1 Evap": (60, 70),
    "Circuit 2 Evap": (60, 70),
    "Circuit 1 Superheat": (60, 70),
    "Circuit 2 Superheat": (60, 70),
    "Cooling Set Point": (60, 70),
    "Cooling Prop. Band": (60, 70),
    "Cooling 2nd Set Point": (60, 70),
    "Heating Set Point": (60, 70),
    "Heating 2nd Set Point": (60, 70),
    "Heating Prop. Band": (60, 70),
}

BASE_OID = ".1.3.6.1.4.1.9839.2.1"
SYSDESC_OID = ".1.3.6.1.2.1.1.1.0"
CAREL_PRESENCE_OID = ".1.3.6.1.4.1.9839.1.1.0"


def _default_levels(sensor_name):
    return _DEFAULT_LEVELS.get(sensor_name, (60, 70))


def _to_float(val):
    cleaned = val
    colon = cleaned.find(":")
    if colon != -1:
        cleaned = cleaned[colon + 1:].strip()
    if len(cleaned) >= 2 and cleaned[0] == '"' and cleaned[-1] == '"':
        cleaned = cleaned[1:-1]
    if len(cleaned) == 0:
        return None
    # Starlark has no try/except; guard with a digit check is not reliable for floats.
    # Use int() first, then attempt float via multiplication-free parse.
    neg = False
    s = cleaned
    if s[0] == "-":
        neg = True
        s = s[1:]
    if len(s) == 0:
        return None
    # Check if it's a valid float string: digits with optional single '.'
    parts = s.split(".")
    if len(parts) == 1:
        if not parts[0].isdigit():
            return None
        val_int = 0
        for ch in parts[0]:
            val_int = val_int * 10 + (ord(ch) - ord('0'))
        result = float(parts[0])
    elif len(parts) == 2:
        int_part = parts[0]
        frac_part = parts[1]
        ok = True
        if len(int_part) > 0 and not int_part.isdigit():
            ok = False
        if not frac_part.isdigit():
            ok = False
        if not ok:
            return None
        result = float(s)
    else:
        return None
    if neg:
        result = 0 - result
    return result


def _parse_sensors(walk_stdout):
    # snmpwalk -Oqn output: "<full-oid> <value>" per line
    sensors = {}
    base_len = len(BASE_OID)
    lines = walk_stdout.splitlines()
    for line in lines:
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        if not oid.startswith(BASE_OID + "."):
            continue
        suffix = oid[base_len + 1:]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col = parts[0]
        index = ".".join(parts[1:])
        if col == "2":
            sensor_name = _OID_PARSE.get(index)
            if sensor_name != None:
                if val in ("0", "-9999", "NOSUCHOBJECT", "NOSUCHINSTANCE"):
                    continue
                temp = _to_float(val)
                if temp != None:
                    sensors[sensor_name] = temp / 10
    return sensors


def _is_carel_device(sysdesc_out, sysdesc_rc):
    if sysdesc_rc == 127:
        return False
    if sysdesc_rc != 0:
        return False
    desc = sysdesc_out.strip()
    if desc.find("pCO") != -1:
        return True
    if desc.endswith("armv4l"):
        return True
    return False


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # ---- Discovery mode ----
    if params.get("_discover"):
        sysdesc = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSDESC_OID],
            mutates=False,
        )
        if sysdesc.rc == 127:
            return {"changed": False, "msg": "not installed", "data": {"discovery": []}}

        if not _is_carel_device(sysdesc.stdout, sysdesc.rc):
            return {"changed": False, "msg": "no pCO device found", "data": {"discovery": []}}

        pres = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, CAREL_PRESENCE_OID],
            mutates=False,
        )
        if pres.rc != 0:
            return {"changed": False, "msg": "no pCO device found", "data": {"discovery": []}}

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, BASE_OID],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no pCO device found", "data": {"discovery": []}}

        sensors = _parse_sensors(walk.stdout)
        out = []
        for sensor_name in sorted(sensors.keys()):
            levels = _default_levels(sensor_name)
            out.append({
                "item": sensor_name,
                "params": {"levels": list(levels)},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out},
        }

    # ---- Check mode (single item) ----
    item = params.get("item", "")

    sysdesc = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSDESC_OID],
        mutates=False,
    )
    if not _is_carel_device(sysdesc.stdout, sysdesc.rc):
        return {
            "changed": False,
            "msg": "no pCO device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, BASE_OID],
        mutates=False,
    )
    if walk.rc != 0:
        return {
            "changed": False,
            "msg": "no sensor data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensors = _parse_sensors(walk.stdout)
    if item not in sensors:
        return {
            "changed": False,
            "msg": "no sensor %s found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    temp = sensors[item]

    levels = params.get("levels")
    if levels == None:
        levels = _default_levels(item)
    warn = levels[0]
    crit = levels[1]

    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    msg = "%s: %f C" % (item, temp)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": msg,
        },
    }