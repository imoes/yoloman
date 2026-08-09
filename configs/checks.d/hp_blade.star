def _get_state_map():
    return {
        1: ("CRIT", "Other"),
        2: ("OK", "Ok"),
        3: ("WARN", "Degraded"),
        4: ("CRIT", "Failed"),
    }


def _strip_type_tag(value):
    idx = value.find(": ")
    if idx != -1:
        value = value[idx + 2:]
    return value


def _snmp_get_oid(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or len(res.stdout) == 0:
        return None
    return _strip_type_tag(res.stdout)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        sys_oid = _snmp_get_oid(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if sys_oid == None:
            return {"changed": False, "msg": "not an HP blade system",
                    "data": {"discovery": []}}

        if ".11.5.7.1.2" not in sys_oid:
            return {"changed": False, "msg": "not an HP blade system",
                    "data": {"discovery": []}}

        firmware = _snmp_get_oid(ctx, host, community, ".1.3.6.1.4.1.232.22.2.3.1.1.1.8")
        raw_state = _snmp_get_oid(ctx, host, community, ".1.3.6.1.4.1.232.22.2.3.1.1.1.16")
        serial = _snmp_get_oid(ctx, host, community, ".1.3.6.1.4.1.232.22.2.3.1.1.1.7")

        if firmware == None and raw_state == None and serial == None:
            return {"changed": False, "msg": "no HP blade enclosure data",
                    "data": {"discovery": []}}

        return {"changed": False, "msg": "discovered General Status",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}

    firmware = _snmp_get_oid(ctx, host, community, ".1.3.6.1.4.1.232.22.2.3.1.1.1.8")
    raw_state = _snmp_get_oid(ctx, host, community, ".1.3.6.1.4.1.232.22.2.3.1.1.1.16")
    serial = _snmp_get_oid(ctx, host, community, ".1.3.6.1.4.1.232.22.2.3.1.1.1.7")

    if firmware == None and raw_state == None and serial == None:
        return {"changed": False,
                "msg": "no HP blade enclosure data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if raw_state == None or not raw_state.isdigit():
        return {"changed": False,
                "msg": "could not read general status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_map = _get_state_map()
    state_code = int(raw_state)
    if state_code not in state_map:
        return {"changed": False,
                "msg": "unknown status code: %s" % raw_state,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state, state_readable = state_map[state_code]
    summary = "General Status is %s (Firmware: %s, S/N: %s)" % (
        state_readable, firmware, serial)

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}