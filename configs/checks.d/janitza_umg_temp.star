# Translated Checkmk check: janitza_umg_temp
# Monitor: Temperature External %s on Janitza UMG power meters (SNMP).

_JANITZA_BASE = ".1.3.6.1.4.1.34278"
_SYSOID_OID = ".1.3.6.1.2.1.1.2.0"

_DEVICE_MAP = {
    ".1.3.6.1.4.1.34278.8.6": "96",
    ".1.3.6.1.4.1.34278.10.1": "604",
    ".1.3.6.1.4.1.34278.10.4": "508",
}

_OFFSETS = {
    "508": {"energy": 4, "sumenergy": 5, "misc": 8},
    "604": {"energy": 4, "sumenergy": 5, "misc": 8},
    "96": {"energy": 3, "sumenergy": 4, "misc": 6},
}

_NO_TEMP = -1000


def _is_int(s):
    if s == None or s == "":
        return False
    ss = s
    if ss[0] == "-":
        ss = ss[1:]
    if ss == "":
        return False
    for ch in ss:
        if ch < "0" or ch > "9":
            return False
    return True


def _grade_temp(value, warn, crit):
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"


def _fetch_snmp_table(ctx, host, community, base, index):
    column_oid = "%s.%d" % (base, index)
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        row_oid = line[:sp]
        row_val = line[sp + 1:]
        idx = row_oid[len(column_oid) + 1:]
        rows.append((idx, row_val))
    def _idx_key(r):
        if _is_int(r[0]):
            return (0, int(r[0]))
        return (1, r[0])
    rows = sorted(rows, key=_idx_key)
    return rows


def _fetch_snmp_scalar(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _probe_device(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sysoid = _fetch_snmp_scalar(ctx, host, community, _SYSOID_OID)
    if sysoid == None:
        return None
    dev_type = _DEVICE_MAP.get(sysoid)
    if dev_type == None:
        return None

    offsets = _OFFSETS[dev_type]

    tables = []
    for i in range(1, 9):
        rows = _fetch_snmp_table(ctx, host, community, _JANITZA_BASE, i)
        tables.append(rows)

    misc_idx = offsets["misc"] - 1
    if misc_idx >= len(tables) or not tables[misc_idx]:
        return {"dev_type": dev_type, "temperature": {}}

    misc_rows = tables[misc_idx]
    if not misc_rows:
        return {"dev_type": dev_type, "temperature": {}}

    first_idx = misc_rows[0][0]
    misc_base = "%s.%d" % (_JANITZA_BASE, offsets["misc"])
    full_base = "%s.%s" % (misc_base, first_idx)
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, "." + full_base], mutates=False)
    raw_vals = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        raw_vals.append(line[sp + 1:])

    if not raw_vals:
        return {"dev_type": dev_type, "temperature": {}}

    temps = {}
    for num, v in enumerate(raw_vals[1:], start=1):
        if not _is_int(v):
            continue
        temp_val = int(v) / 10.0
        temps[str(num)] = temp_val
    return {"dev_type": dev_type, "temperature": temps}


def main(ctx, params):
    if params.get("_discover"):
        probe = _probe_device(ctx, params)
        if probe == None:
            return {"changed": False, "msg": "no Janitza UMG device found",
                    "data": {"discovery": [], "details": "sysObjectID not matching a Janitza UMG"}}
        temps = probe["temperature"]
        discovery = []
        for num, val in temps.items():
            if val != _NO_TEMP:
                discovery.append({"item": num, "params": {}, "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery, "details": ""}}

    item = params.get("item", "")
    warn = params.get("warn", None)
    crit = params.get("crit", None)

    probe = _probe_device(ctx, params)
    if probe == None:
        return {"changed": False, "msg": "no Janitza UMG device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "device not present"}}
    temps = probe["temperature"]
    if item not in temps:
        return {"changed": False, "msg": "no temperature sensor %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val = temps[item]
    if val == _NO_TEMP:
        return {"changed": False, "msg": "sensor %s reports no temperature" % item,
                "data": {"state": "UNKNOWN", "metrics": {"temperature": val}, "details": ""}}
    state = _grade_temp(val, warn, crit)
    label = "Temperature External %s" % item
    return {"changed": False,
            "msg": "%s: %f C" % (label, val),
            "data": {"state": state, "metrics": {"temperature": val}, "details": str(val) + " C"}}