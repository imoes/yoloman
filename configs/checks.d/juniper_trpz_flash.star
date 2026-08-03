def _to_float(s):
    if s == None:
        return None
    if type(s) == "string":
        if s == "":
            return None
        neg = False
        t = s
        if t.startswith("-"):
            neg = True
            t = t[1:]
        if not t:
            return None
        if "." in t:
            parts = t.split(".")
            if len(parts) != 2:
                return None
            intpart = parts[0]
            fracpart = parts[1]
            if intpart == "" and fracpart == "":
                return None
            if intpart == "" and fracpart == "":
                return None
            ok = True
            if intpart:
                if not _is_digits(intpart):
                    ok = False
            if not _is_digits(fracpart):
                ok = False
            if not ok:
                return None
            val = 0.0
            if intpart:
                val = _parse_int(intpart)
            for i in range(len(fracpart)):
                val = val + _digit_val(fracpart[i]) * _fp(10, i + 1)
            return val if not neg else 0 - val
        if not _is_digits(t):
            return None
        val = _parse_int(t)
        return float(val) if not neg else 0 - float(val)
    return None

def _is_digits(s):
    if s == "":
        return False
    for c in s:
        if not _is_digit(c):
            return False
    return True

def _is_digit(c):
    return c in "0123456789"

def _digit_val(c):
    d = "0123456789".find(c)
    if d < 0:
        return 0
    return d

def _parse_int(s):
    v = 0
    for c in s:
        v = v * 10 + _digit_val(c)
    return v

def _fp(base, exp):
    r = 1.0
    for _ in range(exp):
        r = r / base
    return r

def _render_bytes(b):
    b = float(b)
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    i = 0
    while b >= 1024 and i < len(units) - 1:
        b = b / 1024.0
        i = i + 1
    if i == 0:
        return "%d B" % int(b)
    return "%f %s" % (b, units[i])

def _is_juniper_trpz(sys_oid):
    if not sys_oid:
        return False
    return sys_oid.startswith(".1.3.6.1.4.1.14525.3")

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        sys_oid = res.stdout.strip() if res.rc == 0 else ""
        if not _is_juniper_trpz(sys_oid):
            return {"changed": False, "msg": "not a Juniper Trapezoid device", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered flash", "data": {"discovery": [{"item": "", "params": {"levels": (90.0, 95.0)}, "metrics": ["used_juniper_trpz_flash"]}]}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.14525.4.8.1.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    sys_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    sys_oid = sys_res.stdout.strip() if sys_res.rc == 0 else ""
    if not _is_juniper_trpz(sys_oid):
        return {"changed": False, "msg": "not a Juniper Trapezoid device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    used_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".3"], mutates=False)
    total_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".4"], mutates=False)

    if used_res.rc != 0 or total_res.rc != 0:
        return {"changed": False, "msg": "flash data unavailable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    used = _to_float(used_res.stdout.strip())
    total = _to_float(total_res.stdout.strip())

    if used == None or total == None:
        return {"changed": False, "msg": "invalid flash values", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", (90.0, 95.0))
    warn = levels[0]
    crit = levels[1]

    perc_used = (used / total) * 100 if total > 0 else 0

    if warn < 100:
        a_warn = (warn / 100.0) * total
        a_crit = (crit / 100.0) * total
        level_str = "Levels Warn/Crit are (%f%%, %f%%)" % (warn, crit)
        if perc_used > crit:
            state = "CRIT"
        elif perc_used > warn:
            state = "WARN"
        else:
            state = "OK"
    else:
        level_str = "Levels Warn/Crit are (%d, %d)" % (int(warn), int(crit))
        if used > crit:
            state = "CRIT"
        elif used > warn:
            state = "WARN"
        else:
            state = "OK"

    msg = "Used: %s of %s %s" % (_render_bytes(used), _render_bytes(total), level_str)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"used_juniper_trpz_flash": used}, "details": ""}}