# Device state id -> (monstate, readable status) for Sentry PDU v4
_DEVICE_STATES_V4 = {
    0: ("OK", "normal"),
    1: ("CRIT", "disabled"),
    2: ("CRIT", "purged"),
    5: ("WARN", "reading"),
    6: ("WARN", "settle"),
    7: ("CRIT", "not found"),
    8: ("CRIT", "lost"),
    9: ("CRIT", "read error"),
    10: ("CRIT", "no comm"),
    11: ("CRIT", "pwr error"),
    12: ("CRIT", "breaker tripped"),
    13: ("CRIT", "fuse blown"),
    14: ("CRIT", "low alarm"),
    15: ("WARN", "low warning"),
    16: ("WARN", "high warning"),
    17: ("CRIT", "high alarm"),
    18: ("CRIT", "alarm"),
    19: ("CRIT", "under limit"),
    20: ("CRIT", "over limit"),
    21: ("CRIT", "nvm fail"),
    22: ("CRIT", "profile error"),
    23: ("CRIT", "conflict"),
}

# SNMP base OID for the Sentry PDU v4 plug table
_BASE_OID = ".1.3.6.1.4.1.1718.4.1.3"
_OID_NAME = "2.1.3"
_OID_STATE = "3.1.2"
_OID_POWER = "3.1.3"
_SYSOID = ".1.3.6.1.2.1.1.2.0"
_SYSOID_VAL = ".1.3.6.1.4.1.1718.4"


def _community(params):
    return params.get("community", "public")


def _host(params):
    return params.get("host", "localhost")


def _get_int(stdout):
    s = stdout.strip()
    if s == "" or (not s.lstrip("-").isdigit()):
        return None
    return int(s)


def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: is this a Sentry PDU v4 device?
        sys_oid = ctx.run(
            ["snmpget", "-v2c", "-c", _community(params), "-Oqv",
             _host(params), _SYSOID],
            mutates=False,
        )
        if sys_oid.rc != 0 or _SYSOID_VAL not in sys_oid.stdout:
            return {"changed": False, "msg": "no Sentry PDU v4 device found",
                    "data": {"discovery": []}}

        # Walk the name column to discover plug items
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", _community(params), "-Oqn",
             _host(params), _BASE_OID + "." + _OID_NAME],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no Sentry PDU v4 plugs discovered",
                    "data": {"discovery": []}}

        discovery = []
        col_base = _BASE_OID + "." + _OID_NAME
        for line in res.stdout.splitlines():
            idx = line.find(" ")
            if idx < 0:
                continue
            col_oid = line[:idx]
            if not col_oid.startswith(col_base + "."):
                continue
            index = col_oid[len(col_base) + 1:]
            name = line[idx + 1:]
            discovery.append({
                "item": index,
                "params": {"warn": 80, "crit": 90},
                "metrics": ["power"],
                "service_labels": {"sentry_name": name},
            })
        return {"changed": False,
                "msg": "discovered %d plugs" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE
    item = params.get("item", "")

    name_res = ctx.run(
        ["snmpget", "-v2c", "-c", _community(params), "-Oqv",
         _host(params), _BASE_OID + "." + _OID_NAME + "." + item],
        mutates=False,
    )
    if name_res.rc != 0:
        return {"changed": False, "msg": "no such plug: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_res = ctx.run(
        ["snmpget", "-v2c", "-c", _community(params), "-Oqv",
         _host(params), _BASE_OID + "." + _OID_STATE + "." + item],
        mutates=False,
    )
    state_int = _get_int(state_res.stdout)
    if state_int == None or state_res.rc != 0:
        return {"changed": False, "msg": "could not read state for plug " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    power_res = ctx.run(
        ["snmpget", "-v2c", "-c", _community(params), "-Oqv",
         _host(params), _BASE_OID + "." + _OID_POWER + "." + item],
        mutates=False,
    )
    power_int = _get_int(power_res.stdout)
    if power_int == None:
        power_int = 0

    if state_int in _DEVICE_STATES_V4:
        monstate, status = _DEVICE_STATES_V4[state_int]
    else:
        monstate = "UNKNOWN"
        status = "state " + str(state_int)

    metrics = {}
    if power_int > 0:
        metrics["power"] = power_int

    return {"changed": False,
            "msg": "Status: %s, Power: %d Watt" % (status, power_int),
            "data": {"state": monstate, "metrics": metrics, "details": ""}}