def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

# SNMP OIDs
#   sysObjectID: 1.3.6.1.2.1.1.2.0  (detect prefix .1.3.6.1.4.1.272.4)
#   sensor table base: 1.3.6.1.4.1.272.4.17.7.1.1.1
#   columns: 2=sensor_id, 3=descr, 4=type, 5=value, 7=unit
_BINTec_OID_PREFIX = ".1.3.6.1.4.1.272.4"
_SYS_OID = ".1.3.6.1.2.1.1.2.0"
_TABLE_BASE = ".1.3.6.1.4.1.272.4.17.7.1.1.1"

def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.strip().split("\n"):
        if not line:
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        rows.append((line[:sp], line[sp + 1:]))
    return rows

def _detect_device(ctx, host, community):
    val = _snmp_get(ctx, host, community, _SYS_OID)
    if val == None:
        return False
    return val.startswith(_BINTec_OID_PREFIX)

def _read_sensors(ctx, host, community):
    """Returns list of (sensor_id, descr, type, value, unit) tuples."""
    descr_rows = _snmp_walk(ctx, host, community, _TABLE_BASE + ".3")
    type_rows = _snmp_walk(ctx, host, community, _TABLE_BASE + ".4")
    value_rows = _snmp_walk(ctx, host, community, _TABLE_BASE + ".5")
    unit_rows = _snmp_walk(ctx, host, community, _TABLE_BASE + ".7")

    type_map = {}
    for oid, v in type_rows:
        type_map[oid] = v
    value_map = {}
    for oid, v in value_rows:
        value_map[oid] = v
    unit_map = {}
    for oid, v in unit_rows:
        unit_map[oid] = v

    sensors = []
    for oid, descr in descr_rows:
        sensor_type = type_map.get(oid, "")
        sensor_value = value_map.get(oid, "")
        sensor_unit = unit_map.get(oid, "")
        sensors.append((oid, descr, sensor_type, sensor_value, sensor_unit))
    return sensors

def _voltage_table(ctx, host, community):
    """Returns discovery/check rows for voltage sensors only."""
    rows = []
    for _sid_oid, descr, stype, sval, _unit in _read_sensors(ctx, host, community):
        if stype == "3":
            rows.append((descr, sval))
    return rows

def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _detect_device(ctx, host, community):
        return {"changed": False, "msg": "no bintec device found", "data": {"discovery": []}}

    voltages = _voltage_table(ctx, host, community)
    discovery = []
    for descr, _val in voltages:
        discovery.append({
            "item": descr,
            "params": {},
            "metrics": ["voltage"],
        })
    return {
        "changed": False,
        "msg": "discovered %d voltage sensors" % len(discovery),
        "data": {"discovery": discovery},
    }

def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    if not _detect_device(ctx, host, community):
        return {
            "changed": False,
            "msg": "no bintec device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    voltages = _voltage_table(ctx, host, community)
    for descr, sval in voltages:
        if descr == item:
            voltage = int(sval) / 1000.0
            return {
                "changed": False,
                "msg": "%s is at %s V" % (item, str(voltage)),
                "data": {
                    "state": "OK",
                    "metrics": {"voltage": voltage},
                    "details": "",
                },
            }

    return {
        "changed": False,
        "msg": "Sensor %s not found" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }