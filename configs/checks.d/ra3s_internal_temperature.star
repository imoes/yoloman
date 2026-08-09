# Translated Checkmk check: ra3s_internal_temperature
# Monitors internal temperature of an AVTech RoomAlert 3S device via SNMP.

def _is_not_installed(res):
    # rc == 127 means the binary is missing
    return res.rc != 0 and (res.rc == 127 or (res.stderr == "" and res.stdout == ""))

def _parse_temp(value_str):
    # value_str is bare (due to -Oqv); parse to float, guard digits
    if value_str == None or value_str == "":
        return None
    sign = 1
    s = value_str
    if s.startswith("-"):
        sign = -1
        s = s[1:]
    elif s.startswith("+"):
        s = s[1:]
    if s == "":
        return None
    # accept optional decimal
    if "." in s:
        parts = s.split(".")
        if len(parts) != 2:
            return None
        int_part = parts[0]
        frac_part = parts[1]
        if int_part == "" and frac_part == "":
            return None
        num_str = int_part + frac_part
        if not num_str.isdigit():
            return None
        value = float(num_str)
        divisor = 1.0
        n = len(frac_part)
        i = 0
        while i < n:
            divisor = divisor * 10.0
            i = i + 1
        value = value / divisor
        return sign * value
    else:
        if not s.isdigit():
            return None
        return sign * float(s)

def _get_internal_temperatures(ctx, params):
    # OID .1.3.6.1.4.1.20916.1.13.1.1.1 = internal temp Fahrenheit (centi-deg)
    # OID .1.3.6.1.4.1.20916.1.13.1.1.2 = internal temp Celsius (centi-deg)
    res_f = ctx.run([
        "snmpget", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.20916.1.13.1.1.1",
    ], mutates=False)
    res_c = ctx.run([
        "snmpget", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.20916.1.13.1.1.2",
    ], mutates=False)
    temp_f = _parse_temp(res_f.stdout.strip())
    temp_c = _parse_temp(res_c.stdout.strip())
    if temp_f != None:
        temp_f = temp_f / 100.0
    if temp_c != None:
        temp_c = temp_c / 100.0
    return temp_f, temp_c

def _check_temperature(reading, params):
    # params: {"levels": (warn, crit)}  defaults (30.0, 35.0)
    levels = params.get("levels", (30.0, 35.0))
    warn = levels[0]
    crit = levels[1]
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"
    return state, reading

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe for the RA3S device presence: check sysObjectID contains
        # 1.3.6.1.4.1.20916 (AVTech enterprises) and sysDescr contains "3S"
        res_obj = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, ".1.3.6.1.2.1.1.2.0",
        ], mutates=False)
        res_desc = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, ".1.3.6.1.2.1.1.1.0",
        ], mutates=False)
        if _is_not_installed(res_obj) or _is_not_installed(res_desc):
            return {"changed": False, "msg": "RA3S device not present", "data": {"discovery": []}}
        oid = res_obj.stdout.strip()
        descr = res_desc.stdout.strip()
        if "20916" not in oid or "3S" not in descr:
            return {"changed": False, "msg": "not an RA3S device", "data": {"discovery": []}}
        # Device is RA3S; internal temperature sensor is always present on real hardware
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "Internal",
                        "params": {"levels": (30.0, 35.0)},
                        "metrics": ["temperature"],
                    },
                ],
                "host_labels": {"cmk/os_family": "embedded"},
            },
        }

    item = params.get("item", "")
    if item != "Internal":
        return {"changed": False, "msg": "no such item", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_f, temp_c = _get_internal_temperatures(ctx, params)
    if temp_c == None and temp_f == None:
        return {
            "changed": False,
            "msg": "internal temperature data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if temp_c != None:
        reading = temp_c
        unit = "C"
        state, reading = _check_temperature(temp_c, params)
        detail = "Temperature: %f C" % reading
    else:
        # Convert Fahrenheit to Celsius for consistent reporting
        reading_c = (temp_f - 32.0) * 5.0 / 9.0
        reading = reading_c
        unit = "F->C"
        state, reading = _check_temperature(reading_c, params)
        detail = "Temperature: %f C (from %f F)" % (reading, temp_f)
    metrics = {"temperature": reading}
    return {
        "changed": False,
        "msg": "%s %s" % (item, detail),
        "data": {"state": state, "metrics": metrics, "details": detail},
    }