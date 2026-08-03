def _get_snmp_value(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if not val:
        return None
    if val.isdigit():
        return int(val)
    return None


def _detect_webgateway(ctx, host, community):
    sys_descr = _get_snmp_value(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
    if sys_descr != None:
        s = str(sys_descr)
        if "mcafee web gateway" in s:
            return ".1.3.6.1.4.1.1230.2.7.2"
        if "skyhigh secure web gateway" in s:
            return ".1.3.6.1.4.1.59732.2.7.2"
    soid = _get_snmp_value(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    soid_str = str(soid) if soid != None else ""
    if "1.3.6.1.4.1.1230.2.7.1.1" in soid_str:
        return ".1.3.6.1.4.1.1230.2.7.2"
    if "1.3.6.1.4.1.59732.2.7.1.1" in soid_str:
        return ".1.3.6.1.4.1.59732.2.7.2"
    return None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        base = _detect_webgateway(ctx, host, community)
        if base == None:
            return {"changed": False, "msg": "no webgateway found", "data": {"discovery": [], "host_labels": {}}}

        http = _get_snmp_value(ctx, host, community, base + ".2.1")
        https = _get_snmp_value(ctx, host, community, base + ".6.1")
        httpv2 = _get_snmp_value(ctx, host, community, base + ".3.1")

        discovery = []
        if http:
            discovery.append({"item": "http", "params": {"levels": (500, 1000)}, "metrics": ["requests_per_second"]})
        if https:
            discovery.append({"item": "https", "params": {"levels": (500, 1000)}, "metrics": ["requests_per_second"]})
        if httpv2:
            discovery.append({"item": "httpv2", "params": {"levels": (500, 1000)}, "metrics": ["requests_per_second"]})

        host_labels = {"cmk/os_family": "webgateway"}
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery, "host_labels": host_labels}}

    item = params.get("item", "")
    levels = params.get("levels", (500, 1000))
    warn = levels[0] if len(levels) >= 1 else 500
    crit = levels[1] if len(levels) >= 2 else 1000

    base = _detect_webgateway(ctx, host, community)
    if base == None:
        return {"changed": False, "msg": "no webgateway found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item == "http":
        oid = base + ".2.1"
        label = "http"
    elif item == "https":
        oid = base + ".6.1"
        label = "https"
    elif item == "httpv2":
        oid = base + ".3.1"
        label = "httpv2"
    else:
        return {"changed": False, "msg": "no such item: " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = _get_snmp_value(ctx, host, community, oid)
    if value == None:
        return {"changed": False, "msg": "no data for " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "%s: %d requests/s" % (label, value)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"requests_per_second": value}, "details": ""}}