def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: the APC InRow device (sysObjectID check).
        sysid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                         params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                        mutates=False)
        if sysid.rc != 0 or sysid.stdout == "":
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": []}}
        if not sysid.stdout.startswith(".1.3.6.1.4.1.318"):
            return {"changed": False, "msg": "not an APC device", "data": {"discovery": []}}

        # Probe the fanspeed OID to confirm the sensor is present.
        fan = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                       params.get("host", "localhost"), ".1.3.6.1.4.1.318.1.1.13.3.2.2.2.16"],
                      mutates=False)
        if fan.rc != 0:
            return {"changed": False, "msg": "fanspeed OID not available", "data": {"discovery": []}}

        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["fan_perc"]}]}}

    # Check mode for the single-instance fanspeed service.
    fan = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"), ".1.3.6.1.4.1.318.1.1.13.3.2.2.2.16"],
                  mutates=False)
    if fan.rc != 0 or fan.stdout == "":
        return {"changed": False,
                "msg": "fanspeed not available (no SNMP response)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sval = fan.stdout.strip()
    pct = _to_float(sval) / 10.0
    return {"changed": False,
            "msg": "Current: %f%%" % pct,
            "data": {"state": "OK", "metrics": {"fan_perc": pct}, "details": ""}}


def _to_float(s):
    if s == None or s == "":
        return 0.0
    v = s.split()[0] if s.split() else "0"
    # Guard: build int/float manually without try/except.
    sign = -1.0 if v.startswith("-") else 1.0
    if v.startswith("-"):
        v = v[1:]
    if v.startswith("+"):
        v = v[1:]
    # Allow at most one dot.
    parts = v.split(".")
    if len(parts) == 1:
        digits = parts[0]
        if digits == "" or not _all_digits(digits):
            return 0.0
        return sign * _to_int(digits)
    if len(parts) == 2:
        intpart = parts[0]
        fracpart = parts[1]
        if intpart == "" and fracpart == "":
            return 0.0
        if intpart == "" and _all_digits(fracpart):
            return sign * (_to_int(fracpart) / _pow10(len(fracpart)))
        if not _all_digits(intpart):
            return 0.0
        if fracpart == "":
            return sign * _to_int(intpart)
        if not _all_digits(fracpart):
            return 0.0
        return sign * (_to_int(intpart) + _to_int(fracpart) / _pow10(len(fracpart)))
    return 0.0


def _to_int(s):
    n = 0
    for ch in s:
        n = n * 10 + (_digit_val(ch))
    return n


def _digit_val(ch):
    if ch == "0":
        return 0
    if ch == "1":
        return 1
    if ch == "2":
        return 2
    if ch == "3":
        return 3
    if ch == "4":
        return 4
    if ch == "5":
        return 5
    if ch == "6":
        return 6
    if ch == "7":
        return 7
    if ch == "8":
        return 8
    if ch == "9":
        return 9
    return 0


def _all_digits(s):
    if s == "":
        return False
    for ch in s:
        if _digit_val(ch) == 0 and ch != "0":
            return False
    return True


def _pow10(n):
    r = 1
    for _ in range(n):
        r = r * 10
    return r