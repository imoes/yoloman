def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.13595.2.1.3.3.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed for emka_modules",
                    "data": {"discovery": []}}

        eq_hex_res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", "-Ox", params.get("host", "localhost"),
            ".1.3.6.1.4.1.13595.2.2.3.1.18"
        ], mutates=False)

        temp_sensor_locations = set()
        for line in eq_hex_res.stdout.splitlines():
            if line.strip() == "":
                continue
            if "=" not in line:
                continue
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oidend = parts[0].strip().split(".")[-1]
            hex_part = parts[1].strip().replace(" ", "")
            if len(hex_part) % 2 != 0:
                continue
            ascii_str = ""
            is_temp = False
            i = 0
            while i < len(hex_part):
                byte_str = hex_part[i:i+2]
                if byte_str == "00":
                    break
                is_hex = True
                for c in byte_str:
                    if c not in "0123456789abcdefABCDEF":
                        is_hex = False
                        break
                if is_hex:
                    byte_val = int(byte_str, 16)
                    ascii_str += chr(byte_val)
                i += 2
            if len(ascii_str) >= 4:
                if ascii_str[0:2] == "=#" and ord(ascii_str[2]) == 176 and ascii_str[3] == "C":
                    is_temp = True
            if is_temp:
                location = oidend.split(".")[0] if "." in oidend else oidend
                temp_sensor_locations.add(location)

        discovered = []
        for loc in temp_sensor_locations:
            discovered.append({
                "item": loc,
                "params": {},
                "metrics": ["temp"]
            })

        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovered),
                "data": {"discovery": discovered}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item is required",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_oid = ".1.3.6.1.4.1.13595.2.2.3.1.4." + item
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), value_oid
    ], mutates=False)

    if res.rc != 0 or "=" not in res.stdout:
        return {"changed": False, "msg": "could not read temperature value for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = res.stdout.split("=")
    if len(parts) < 2:
        return {"changed": False, "msg": "could not parse temperature value for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_value_str = parts[1].strip().split(":")[-1].strip()
    if raw_value_str == "":
        return {"changed": False, "msg": "could not parse temperature value for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    valid_digits = True
    for c in raw_value_str:
        if c not in "0123456789.-":
            valid_digits = False
            break
    if not valid_digits:
        return {"changed": False, "msg": "could not parse temperature value for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw_value = float(raw_value_str)

    levels_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.13595.2.2.3.1.7." + item + ".2"
    ], mutates=False)

    lower_levels_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.13595.2.2.3.1.7." + item + ".1"
    ], mutates=False)

    levels = None
    lower_levels = None

    if levels_res.rc == 0 and "=" in levels_res.stdout:
        val_str = levels_res.stdout.split("=")[-1].strip().split(":")[-1].strip()
        if val_str != "":
            valid_digits = True
            for c in val_str:
                if c not in "0123456789.-":
                    valid_digits = False
                    break
            if valid_digits:
                levels = float(val_str)

    if lower_levels_res.rc == 0 and "=" in lower_levels_res.stdout:
        val_str = lower_levels_res.stdout.split("=")[-1].strip().split(":")[-1].strip()
        if val_str != "":
            valid_digits = True
            for c in val_str:
                if c not in "0123456789.-":
                    valid_digits = False
                    break
            if valid_digits:
                lower_levels = float(val_str)

    warn_upper = 25.0
    crit_upper = 30.0
    warn_lower = -10.0
    crit_lower = -5.0

    levels_tuple = params.get("levels")
    if levels_tuple != None and len(levels_tuple) >= 2:
        s0 = str(levels_tuple[0])
        s1 = str(levels_tuple[1])
        v0_ok = True
        v1_ok = True
        for c in s0:
            if c not in "0123456789.-":
                v0_ok = False
                break
        for c in s1:
            if c not in "0123456789.-":
                v1_ok = False
                break
        if v0_ok and v1_ok:
            warn_upper = float(s0)
            crit_upper = float(s1)

    lower_levels_tuple = params.get("levels_lower")
    if lower_levels_tuple != None and len(lower_levels_tuple) >= 2:
        s0 = str(lower_levels_tuple[0])
        s1 = str(lower_levels_tuple[1])
        v0_ok = True
        v1_ok = True
        for c in s0:
            if c not in "0123456789.-":
                v0_ok = False
                break
        for c in s1:
            if c not in "0123456789.-":
                v1_ok = False
                break
        if v0_ok and v1_ok:
            warn_lower = float(s0)
            crit_lower = float(s1)

    if levels != None:
        warn_upper = levels
        crit_upper = levels
    if lower_levels != None:
        warn_lower = lower_levels
        crit_lower = lower_levels

    value = raw_value
    state = "OK"
    if value >= crit_upper:
        state = "CRIT"
    elif value >= warn_upper:
        state = "WARN"
    elif value <= crit_lower:
        state = "CRIT"
    elif value <= warn_lower:
        state = "WARN"

    msg = "Temperature %f C" % value

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": value},
            "details": "",
        },
    }