# Checkmk check janitza_umg_freq — Frequency check for JANITZA UMG power meters
# Translated to read-only Starlark. Polls SNMP OIDs directly (no Checkmk agent).

JANITZA_OID_BASE = ".1.3.6.1.4.1.34278"
SYS_OID = ".1.3.6.1.2.1.1.2.0"

# sysoid -> device type / fetch index for misc
DEVICE_MAP = {
    ".1.3.6.1.4.1.34278.8.6": "96",
    ".1.3.6.1.4.1.34278.10.1": "604",
    ".1.3.6.1.4.1.34278.10.4": "508",
}

# per device type: which SNMPTree index holds the misc column (frequency/temperature)
MISC_INDEX = {
    "508": 8,
    "604": 8,
    "96": 6,
}


def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _read_sysoid(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_OID],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _get_device_type(sysoid):
    if sysoid in DEVICE_MAP:
        return DEVICE_MAP[sysoid]
    return None


def _snmpwalk_column(ctx, params, host, community, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0:
        return {}
    result = {}
    base_len = len(column_oid) + 1
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        if len(oid) > base_len:
            index = oid[base_len:]
        else:
            index = "0"
        result[index] = val
    return result


def _read_misc(ctx, params, device_type):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    index = MISC_INDEX[device_type]
    column_oid = JANITZA_OID_BASE + ".%d" % index
    # -Oqn walk returns one line: "<column_oid>.<index> val1 val2 ..."
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        # value is everything after the oid; split into numeric entries
        return line[sp + 1:].split()
    return []


def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sysoid = _read_sysoid(ctx, params)
    if sysoid == None:
        return {"changed": False, "msg": "no janitza umg device found (sysoid not janitza)", "data": {"discovery": []}}
    device_type = _get_device_type(sysoid)
    if device_type == None:
        return {"changed": False, "msg": "not a janitza umg device", "data": {"discovery": []}}
    misc = _read_misc(ctx, params, device_type)
    if len(misc) == 0:
        return {"changed": False, "msg": "no frequency data found", "data": {"discovery": []}}
    return {"changed": False, "msg": "discovered 1 frequency item", "data": {"discovery": [
        {"item": "1", "params": {"levels_lower": params.get("levels_lower", (0, 0))}, "metrics": ["frequency"]}
    ]}}


def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sysoid = _read_sysoid(ctx, params)
    if sysoid == None:
        return {"changed": False, "msg": "no janitza umg device found (sysoid not janitza)", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    device_type = _get_device_type(sysoid)
    if device_type == None:
        return {"changed": False, "msg": "not a janitza umg device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    misc = _read_misc(ctx, params, device_type)
    if len(misc) == 0:
        return {"changed": False, "msg": "no frequency data found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    frequency = int(misc[0]) / 100.0
    levels = params.get("levels_lower", (0, 0))
    warn = levels[0] if len(levels) > 0 else 0
    crit = levels[1] if len(levels) > 1 else 0
    state = "OK"
    if crit != None and crit != 0 and frequency <= crit:
        state = "CRIT"
    elif warn != None and warn != 0 and frequency <= warn:
        state = "WARN"
    msg = "Frequency: %f Hz" % frequency
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"frequency": frequency}, "details": ""}}