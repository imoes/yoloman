# Translated from Checkmk check: checkmk.vutlan_ems_smoke
# Vutlan EMS smoke detector sensors (SNMP).
# Reads the same SNMP table the Checkmk SimpleSNMPSection reads:
#   base = .1.3.6.1.4.1.39052.1.3.1
#   OIDEnd()        -> index (full OID suffix identifies the sensor)
#   "7"  -> ctlUnitElementName (sensor name, user-definable)
#   "9"  -> ctlUnitElementValue (state: 0 = no smoke, nonzero = smoke)
# Only sensors whose index OID starts with "106" are smoke-related.

BASE_OID = ".1.3.6.1.4.1.39052.1.3.1"
COL_NAME = "7"
COL_VALUE = "9"
SMOKE_PREFIX = "106"
ZERO = "0"


def _is_nonneg_int(s):
    if s == "":
        return False
    for ch in s:
        if ch < "0" or ch > "9":
            return False
    return True


def _snmp_get(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        idx = line.find(" ")
        if idx < 0:
            continue
        oid_part = line[:idx]
        value_part = line[idx + 1:]
        rows.append((oid_part, value_part))
    return rows


def _sys_descr(ctx, community, host):
    return _snmp_get(ctx, community, host, ".1.3.6.1.2.1.1.1.0")


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    discover = params.get("_discover", False)

    sys_descr = _sys_descr(ctx, community, host)
    if sys_descr == None or sys_descr == "":
        if discover:
            return {"changed": False, "msg": "no SNMP response / host unreachable",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "Vutlan EMS not detected (no sysDescr)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if sys_descr.find("vutlan ems") < 0:
        if discover:
            return {"changed": False, "msg": "host is not a Vutlan EMS",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "host is not a Vutlan EMS",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name_rows = _snmp_walk(ctx, community, host, BASE_OID + "." + COL_NAME)
    sensors = []
    for oid_part, value_part in name_rows:
        stem = BASE_OID + "." + COL_NAME
        if not oid_part.startswith(stem + "."):
            continue
        index = oid_part[len(stem) + 1:]
        if not index.startswith(SMOKE_PREFIX):
            continue
        sensors.append((index, value_part))

    if discover:
        discovery = []
        for index, name in sensors:
            discovery.append({
                "item": name,
                "params": {},
                "metrics": [],
            })
        return {"changed": False,
                "msg": "discovered %d smoke sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    target = None
    for index, name in sensors:
        if name == item:
            target = (index, name)
            break

    if target == None:
        return {"changed": False,
                "msg": "no such smoke sensor: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    index, name = target
    state_oid = BASE_OID + "." + COL_VALUE + "." + index
    state_val = _snmp_get(ctx, community, host, state_oid)
    if state_val == None:
        return {"changed": False,
                "msg": "could not read smoke sensor state: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # state: 0 = no smoke, nonzero = smoke detected.
    st = -1
    if state_val == "":
        st = -1
    elif _is_nonneg_int(state_val):
        st = int(state_val)

    if st != 0:
        return {"changed": False,
                "msg": "Smoke detected",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    return {"changed": False,
            "msg": "No smoke detected",
            "data": {"state": "OK", "metrics": {}, "details": ""}}