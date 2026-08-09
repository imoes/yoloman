# Checkmk check → read-only Starlark check module
# icom_repeater_pll_volt: %s PLL Lock Voltage (per TX/RX)

ICOM_BASE = ".1.3.6.1.4.1.2021.8.1"
SYSTEM_OID = ".1.3.6.1.2.1.1.1.0"
COL_IDX = "1"
COL_NAME = "2"
COL_VALUE = "101"


def _snmp_get_int(ctx, oid, community, host):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    s = res.stdout.strip()
    if s == "" or s == "No Such Instance":
        return None
    if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
        return int(s)
    if _is_float(s):
        return float(s)
    return None


def _is_float(s):
    if s == "":
        return False
    i = 0
    n = len(s)
    if s[0] == "-":
        i = 1
    seen_digit = False
    seen_dot = False
    while i < n:
        c = s[i]
        if c >= "0" and c <= "9":
            seen_digit = True
        elif c == "." and not seen_dot:
            seen_dot = True
        else:
            return False
        i += 1
    return seen_digit


def _snmp_walk_table(ctx, community, host):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ICOM_BASE], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return {}
    table = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        parts = oid.split(".")
        if len(parts) < 3:
            continue
        col = parts[2]
        idx = ".".join(parts[3:])
        if idx == "":
            idx = "0"
        if idx not in table:
            table[idx] = {}
        table[idx][col] = value
    return table


def _detect_active(ctx, community, host):
    sys_res = ctx.run(["snmpget", "-v2c", "-c", community, "-OvQ", host, SYSTEM_OID], mutates=False)
    if sys_res.rc != 0:
        return False
    return "fr5000" in sys_res.stdout.upper()


def _parse_section(table):
    parsed = {}
    for idx in sorted(table.keys()):
        row = table[idx]
        name = row.get(COL_NAME, "")
        value = row.get(COL_VALUE, "")
        low = name.lower()
        if low == "temperature":
            parsed["temp"] = float(value[:-1]) if len(value) > 1 and _is_float(value[:-1]) else 0.0
            parsed["temp_devunit"] = value[-1:].lower() if value else ""
        elif low == "esn number":
            parsed["esnno"] = value
        elif low == "repeater operation":
            parsed["repop"] = value.lower()
        elif low == "abnormal temperature detection":
            parsed["temp_devstatus"] = 0 if value == "Not detected" else 2
        elif low == "power-supply voltage":
            parsed["ps_voltage"] = float(value[:-1]) if _is_float(value[:-1]) else 0.0
        elif low == "abnormal power-supply voltage detection":
            parsed["ps_volt_devstatus"] = 0 if value == "Not detected" else 2
        elif low == "tx pll lock voltage":
            parsed["tx_pll_lock_voltage"] = float(value[:-1]) if _is_float(value[:-1]) else 0.0
        elif low == "rx pll lock voltage":
            parsed["rx_pll_lock_voltage"] = float(value[:-1]) if _is_float(value[:-1]) else 0.0
        elif low == "repeater frequency":
            freq = {}
            for part in value.split(","):
                p = part.lstrip()
                sp = p.find(":")
                if sp >= 0:
                    k = p[:sp].lower()
                    v = p[sp + 1:].strip()
                    freq[k] = int(v) if _is_float(v) else 0
            parsed["repeater_frequency"] = freq
    return parsed


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        if not _detect_active(ctx, community, host):
            return {"changed": False, "msg": "no Icom repeater found",
                    "data": {"discovery": []}}
        table = _snmp_walk_table(ctx, community, host)
        if not table:
            return {"changed": False, "msg": "no Icom repeater data",
                    "data": {"discovery": []}}
        section = _parse_section(table)
        items = []
        if "rx_pll_lock_voltage" in section:
            items.append({"item": "RX", "params": {}, "metrics": ["voltage"]})
        if "tx_pll_lock_voltage" in section:
            items.append({"item": "TX", "params": {}, "metrics": ["voltage"]})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    # Check mode — single item
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if not _detect_active(ctx, community, host):
        return {"changed": False, "msg": "no Icom repeater found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    table = _snmp_walk_table(ctx, community, host)
    if not table:
        return {"changed": False, "msg": "no Icom repeater data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_section(table)
    key = item.lower() + "_pll_lock_voltage"
    if key not in section:
        return {"changed": False, "msg": "no PLL voltage for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if "repeater_frequency" not in section or item.lower() not in section["repeater_frequency"]:
        return {"changed": False, "msg": "no frequency for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    voltage = section[key]
    freq = section["repeater_frequency"][item.lower()]
    paramlist = params.get(item.lower(), None)
    if not paramlist:
        return {"changed": False, "msg": "Please specify parameters for PLL voltage",
                "data": {"state": "WARN", "metrics": {"voltage": voltage}, "details": ""}}
    warn_lower = None
    crit_lower = None
    warn = None
    crit = None
    i = 0
    n = len(paramlist)
    while i < n:
        entry = paramlist[i]
        if len(entry) >= 1 and entry[0] >= freq:
            if i > 0:
                prev = paramlist[i - 1]
                if len(prev) >= 5:
                    warn_lower = prev[1]
                    crit_lower = prev[2]
                    warn = prev[3]
                    crit = prev[4]
            break
        i += 1
    if warn_lower == None or crit_lower == None or warn == None or crit == None:
        return {"changed": False, "msg": "Please specify parameters for PLL voltage",
                "data": {"state": "WARN", "metrics": {"voltage": voltage}, "details": ""}}
    if voltage < crit_lower or voltage >= crit:
        status = "CRIT"
    elif voltage < warn_lower or voltage >= warn:
        status = "WARN"
    else:
        status = "OK"
    levelstext = " (warn/crit below %f/%f V and at or above %f/%f V)" % (
        warn_lower, crit_lower, warn, crit)
    infotext = "%f V%s" % (voltage, levelstext) if status != "OK" else "%f V" % voltage
    return {"changed": False, "msg": infotext,
            "data": {"state": status, "metrics": {"voltage": voltage}, "details": ""}}