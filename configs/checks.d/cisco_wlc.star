def _detect_is_cisco_wlc(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    ver = params.get("snmp_version", "2c")
    res = ctx.run(["snmpget", "-v" + ver, "-c", community, "-Ovqn", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return False
    parts = res.stdout.split()
    if len(parts) < 2:
        return False
    oid = parts[0]
    if not oid.startswith("."):
        oid = "." + oid
    for dev in _DEVICE_OIDS:
        if oid == dev:
            return True
    return False


_DEVICE_OIDS = [
    ".1.3.6.1.4.1.14179.1.1.4.3",
    ".1.3.6.1.4.1.9.1.1069",
    ".1.3.6.1.4.1.9.1.1279",
    ".1.3.6.1.4.1.9.1.1293",
    ".1.3.6.1.4.1.9.1.1615",
    ".1.3.6.1.4.1.9.1.1631",
    ".1.3.6.1.4.1.9.1.1645",
    ".1.3.6.1.4.1.9.1.2170",
    ".1.3.6.1.4.1.9.1.2171",
    ".1.3.6.1.4.1.9.1.2250",
    ".1.3.6.1.4.1.9.1.2370",
    ".1.3.6.1.4.1.9.1.2371",
    ".1.3.6.1.4.1.9.1.2391",
    ".1.3.6.1.4.1.9.1.2427",
    ".1.3.6.1.4.1.9.1.2530",
    ".1.3.6.1.4.1.9.1.2669",
    ".1.3.6.1.4.1.9.1.2860",
    ".1.3.6.1.4.1.9.1.2861",
    ".1.3.6.1.4.1.9.1.3323",
    ".1.3.6.1.4.1.9.1.3324",
]

map_states = {
    "1": ("OK", "online"),
    "2": ("CRIT", "critical"),
    "3": ("WARN", "warning"),
}


def _snmp_walk(ctx, params, column_oid):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    ver = params.get("snmp_version", "2c")
    res = ctx.run(
        ["snmpwalk", "-v" + ver, "-c", community, "-Oqv", host, column_oid],
        mutates=False,
    )
    return res


def main(ctx, params):
    if params.get("_discover"):
        if not _detect_is_cisco_wlc(ctx, params):
            return {"changed": False, "msg": "not a Cisco WLC", "data": {"discovery": []}}
        res = _snmp_walk(ctx, params, ".1.3.6.1.4.1.14179.2.2.1.1.3")
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no Cisco WLC APs found", "data": {"discovery": []}}
        ap_names = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0]
            value = parts[1]
            idx = oid_full[len(".1.3.6.1.4.1.14179.2.2.1.1.3"):]
            ap_names[idx] = value
        if len(ap_names) == 0:
            return {"changed": False, "msg": "no Cisco WLC APs found", "data": {"discovery": []}}
        discovery = []
        for idx, name in ap_names.items():
            discovery.append({"item": name, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d access points" % len(discovery),
            "data": {"discovery": discovery},
        }
    item = params.get("item", "")
    res = _snmp_walk(ctx, params, ".1.3.6.1.4.1.14179.2.2.1.1")
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "no Cisco WLC AP data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0]
        value = parts[1]
        suffix = oid_full[len(".1.3.6.1.4.1.14179.2.2.1.1"):]
        if suffix == "3":
            idx = ""
            section["__apname__"] = value
        elif suffix == "6":
            section["__status__"] = value
    if "__apname__" in section and section.get("__apname__") == item:
        wlc_status = section.get("__status__", "0")
        state_readable = map_states.get(wlc_status)
        if state_readable:
            state, summary = state_readable
        else:
            state = "UNKNOWN"
            summary = "unknown[%s]" % wlc_status
        return {
            "changed": False,
            "msg": "Accesspoint: %s" % summary,
            "data": {"state": state, "metrics": {}, "details": ""},
        }
    if item not in section:
        return {
            "changed": False,
            "msg": "Accesspoint not found",
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }
    wlc_status = section[item]
    if wlc_status in map_states:
        state, summary = map_states[wlc_status]
    else:
        state = "UNKNOWN"
        summary = "unknown[%s]" % wlc_status
    return {
        "changed": False,
        "msg": "Accesspoint: %s" % summary,
        "data": {"state": state, "metrics": {}, "details": ""},
    }