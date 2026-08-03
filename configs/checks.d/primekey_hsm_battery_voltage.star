def _to_int(v):
    s = str(v).strip()
    if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
        return int(s)
    return 0

def _to_float(v):
    s = str(v).strip()
    if not s:
        return None
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    elif s.startswith("+"):
        s = s[1:]
    if "." in s:
        parts = s.split(".")
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            val = float(s)
            return -val if neg else val
        return None
    if s.isdigit():
        val = float(s)
        return -val if neg else val
    return None

def _parse_voltage(entry):
    if "absence" in entry:
        return "absence"
    v = entry
    suffix = " V"
    if v.endswith(suffix):
        v = v[:-len(suffix)]
    return _to_float(v)

def _fmt_voltage(v):
    if v == None:
        return "no"
    s = "%f" % v
    if "." in s:
        s = s.rstrip("0")
        s = s.rstrip(".")
    return s

BASE_OID = ".1.3.6.1.4.1.22408.1.1.2.2.4.104.115.109"
COL_VOLTAGE = "52.1"
COL_STATUS = "53.1"
COL_VOLTAGE2 = "55.1"
COL_STATUS2 = "56.1"
CHECK_OID = ".1.3.6.1.2.1.1.2.0"
CHECK_VAL = ".1.3.6.1.4.1.8072.3.2.10"

def main(ctx, params):
    if params.get("_discover"):
        detect = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), CHECK_OID], mutates=False)
        if detect.rc != 0:
            return {"changed": False, "msg": "PrimeKey not detected", "data": {"discovery": []}}
        sys_oid = detect.stdout.strip()
        if sys_oid != CHECK_VAL:
            return {"changed": False, "msg": "PrimeKey not detected", "data": {"discovery": []}}
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn", params.get("host", "localhost"), BASE_OID], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "PrimeKey not detected (walk failed)", "data": {"discovery": []}}
        discovery = [{"item": "1", "params": {"levels": None, "levels_lower": None}, "metrics": ["voltage"]}, {"item": "2", "params": {"levels": None, "levels_lower": None}, "metrics": ["voltage"]}]
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    col_v = COL_VOLTAGE
    col_s = COL_STATUS
    if item == "2":
        col_v = COL_VOLTAGE2
        col_s = COL_STATUS2
    elif item != "1":
        return {"changed": False, "msg": "unknown battery item: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "unknown battery item"}}
    g = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), BASE_OID + "." + col_v], mutates=False)
    gs = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), BASE_OID + "." + col_s], mutates=False)
    if g.rc != 0 or gs.rc != 0:
        return {"changed": False, "msg": "PrimeKey HSM battery %s not reachable" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP query failed"}}
    voltage = _parse_voltage(g.stdout.strip())
    state_fail = bool(_to_int(gs.stdout.strip()))
    if voltage == "absence":
        return {"changed": False, "msg": "PrimeKey HSM battery %s status absence" % item, "data": {"state": "OK", "metrics": {}, "details": "battery absence reported"}}
    levels = params.get("levels", None)
    levels_lower = params.get("levels_lower", None)
    warn_upper = None
    crit_upper = None
    warn_lower = None
    crit_lower = None
    if levels != None:
        if len(levels) == 2:
            warn_upper = levels[0]
            crit_upper = levels[1]
    if levels_lower != None:
        if len(levels_lower) == 2:
            warn_lower = levels_lower[0]
            crit_lower = levels_lower[1]
    metric_val = 0.0
    if voltage != None:
        metric_val = voltage
    state = "OK"
    if state_fail:
        state = "CRIT"
    if voltage == None:
        msg = "PrimeKey HSM battery %s status OK" % item
        return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {}, "details": "no voltage value"}}
    if warn_upper != None and crit_upper != None:
        if voltage >= crit_upper:
            state = "CRIT"
        elif voltage >= warn_upper:
            if state == "OK":
                state = "WARN"
    if warn_lower != None and crit_lower != None:
        if voltage <= crit_lower:
            state = "CRIT"
        elif voltage <= warn_lower:
            if state == "OK":
                state = "WARN"
    msg = "PrimeKey HSM battery %s status OK, %s V" % (item, _fmt_voltage(voltage))
    if state_fail:
        msg = "PrimeKey HSM battery %s status not OK, %s V" % (item, _fmt_voltage(voltage))
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"voltage": metric_val}, "details": "voltage=%s state_fail=%s" % (str(voltage), str(state_fail))}}