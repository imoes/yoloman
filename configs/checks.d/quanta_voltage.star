# Checkmk check: checkmk.quanta_voltage
# Translated to read-only Starlark check module for the yolo-man agent.
# Monitors Quanta voltage sensors via SNMP (OID base .1.3.6.1.4.1.7244.1.2.1.3.5.1).
# READ-ONLY: never mutates the system. Always changed=False.

_STATUS_MAP = {
    "1": ("WARN", "other"),
    "2": ("UNKNOWN", "unknown"),
    "3": ("OK", "OK"),
    "4": ("WARN", "non critical upper"),
    "5": ("CRIT", "critical upper"),
    "6": ("CRIT", "non recoverable upper"),
    "7": ("WARN", "non critical lower"),
    "8": ("CRIT", "critical lower"),
    "9": ("CRIT", "non recoverable lower"),
    "10": ("CRIT", "failed"),
}


def _is_float(s):
    if s == None:
        return False
    s = str(s).strip()
    if s == "" or s == "-99":
        return False
    neg = False
    t = s
    if t.startswith("-"):
        neg = True
        t = t[1:]
    if t == "":
        return False
    if t.count(".") > 1:
        return False
    digits = "0123456789"
    seen_digit = False
    seen_dot = False
    for ch in t:
        if ch == ".":
            if seen_dot:
                return False
            seen_dot = True
        elif ch in digits:
            seen_digit = True
        else:
            return False
    return seen_digit


def _to_float(s):
    if not _is_float(s):
        return None
    return float(str(s).strip())


def _validate_levels(dev_warn, dev_crit):
    crit = None
    warn = None
    if dev_crit != None and dev_crit != "-99" and str(dev_crit).strip() != "":
        crit = float(dev_crit)
    if dev_warn != None and dev_warn != "-99" and str(dev_warn).strip() != "":
        warn = float(dev_warn)
    elif crit != None:
        warn = crit
    return warn, crit


def _grade_levels(value, levels_upper, levels_lower):
    state = "OK"
    details = ""
    if levels_upper != None:
        warn, crit = levels_upper
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
        details = "upper: %f/%f" % (warn, crit)
    if levels_lower != None:
        warn, crit = levels_lower
        if state != "CRIT":
            if value <= crit:
                state = "CRIT"
            elif value <= warn:
                if state == "OK":
                    state = "WARN"
        if details == "":
            details = "lower: %f/%f" % (warn, crit)
        else:
            details = details + ", lower: %f/%f" % (warn, crit)
    return state, details


def _detect_quanta(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    sysoid = res.stdout.strip()
    if not sysoid.startswith(".1.3.6.1.4.1.8072.3.2.10"):
        return False
    chk = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", host, ".1.3.6.1.4.1.7244.1.2.1.1.1.0"],
        mutates=False,
    )
    if chk.rc != 0:
        return False
    return True


def _walk_voltage(ctx, host, community):
    base = ".1.3.6.1.4.1.7244.1.2.1.3.5.1"
    cols = ["1", "2", "3", "4", "6", "7", "8", "9"]
    col_map = {}
    for col in cols:
        oid = base + "." + col
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-Oa", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            full_oid = line[:sp].strip()
            val = line[sp + 1:].strip()
            suffix = full_oid[len(oid) + 1:]
            col_map.setdefault(col, {})[suffix] = val
    indices = []
    seen = {}
    for col in cols:
        for idx in col_map.get(col, {}):
            if idx not in seen:
                seen[idx] = True
                indices.append(idx)
    if len(indices) == 0:
        return []
    items = []
    for idx in indices:
        c = {}
        for col in cols:
            c[col] = col_map.get(col, {}).get(idx, "")
        dev_index = c["1"]
        dev_status = c["2"]
        dev_name = c["3"].replace("\x01", "")
        dev_value = c["4"]
        dev_upper_crit = c["6"]
        dev_upper_warn = c["7"]
        dev_lower_warn = c["8"]
        dev_lower_crit = c["9"]
        if dev_name == "":
            dev_name = str(dev_index)
        value = _to_float(dev_value)
        lower_levels = _validate_levels(dev_lower_warn, dev_lower_crit)
        upper_levels = _validate_levels(dev_upper_warn, dev_upper_crit)
        items.append({
            "item": dev_name,
            "status": _STATUS_MAP.get(dev_status, ("UNKNOWN", "unknown[%s]" % dev_status)),
            "value": value,
            "lower_levels": lower_levels,
            "upper_levels": upper_levels,
        })
    return items


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _detect_quanta(ctx, host, community):
            return {"changed": False, "msg": "not a Quanta device", "data": {"discovery": []}}
        items = _walk_voltage(ctx, host, community)
        discovery = []
        for it in items:
            discovery.append({
                "item": it["item"],
                "params": {"levels": it["upper_levels"], "levels_lower": it["lower_levels"]},
                "metrics": ["voltage"],
                "service_labels": {},
            })
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not _detect_quanta(ctx, host, community):
        return {
            "changed": False,
            "msg": "not a Quanta device (no voltage data)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    items = _walk_voltage(ctx, host, community)
    found = None
    for it in items:
        if it["item"] == item:
            found = it
            break
    if found == None:
        return {
            "changed": False,
            "msg": "no such voltage sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    st, summary = found["status"]
    msg = "Status: " + summary
    metrics = {}
    details = summary

    value = found["value"]
    if value == None:
        return {
            "changed": False,
            "msg": msg,
            "data": {"state": st, "metrics": metrics, "details": details},
        }

    metrics["voltage"] = value

    levels_upper = params.get("levels", found["upper_levels"])
    levels_lower = params.get("levels_lower", found["lower_levels"])

    state = st
    if value != None:
        lvl_state, lvl_details = _grade_levels(value, levels_upper, levels_lower)
        if lvl_details != "":
            if details == "":
                details = lvl_details
            else:
                details = details + ", " + lvl_details
        if state == "OK" and lvl_state != "OK":
            state = lvl_state
        elif state == "WARN" and lvl_state == "CRIT":
            state = "CRIT"

    msg = msg + ", Voltage: %f V" % value

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": details},
    }