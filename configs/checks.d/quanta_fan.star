def main(ctx, params):
    if params.get("_discover"):
        sysid_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid_res.rc != 0 or sysid_res.stdout == "":
            return {"changed": False, "msg": "not a Quanta device", "data": {"discovery": []}}
        if not sysid_res.stdout.startswith(".1.3.6.1.4.1.8072.3.2.10"):
            return {"changed": False, "msg": "not a Quanta device", "data": {"discovery": []}}
        probe_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.7244.1.2.1.1.1.0"],
            mutates=False,
        )
        if probe_res.rc != 0:
            return {"changed": False, "msg": "not a Quanta device", "data": {"discovery": []}}
        base = ".1.3.6.1.4.1.7244.1.2.1.3.3.1"
        name_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn", params.get("host", "localhost"), base + ".3"], mutates=False)
        if name_res.rc != 0:
            return {"changed": False, "msg": "no quanta_fan data", "data": {"discovery": []}}
        discovery = []
        for line in name_res.stdout.splitlines():
            sep = line.find(" ")
            if sep == -1:
                continue
            oid = line[:sep]
            name = line[sep + 1:].strip().strip('"')
            idx = oid[len(base + ".3") + 1:]
            if idx == "":
                continue
            discovery.append({"item": name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d fan items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base = ".1.3.6.1.4.1.7244.1.2.1.3.3.1"
    name_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Opn", host, base + ".3"], mutates=False)
    if name_res.rc != 0 or name_res.stdout == "":
        return {"changed": False, "msg": "no quanta_fan data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    idx = ""
    for line in name_res.stdout.splitlines():
        sep = line.find(" ")
        if sep == -1:
            continue
        oid = line[:sep]
        name = line[sep + 1:].strip().strip('"')
        if name == item:
            idx = oid[len(base + ".3") + 1:]
            break
    if idx == "":
        return {"changed": False, "msg": "no such fan item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def snmp_get(oid):
        r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if r.rc != 0:
            return ""
        return r.stdout.strip().strip('"')

    dev_status = snmp_get(base + ".2." + idx)
    dev_value = snmp_get(base + ".4." + idx)
    dev_upper_crit = snmp_get(base + ".6." + idx)
    dev_upper_warn = snmp_get(base + ".7." + idx)
    dev_lower_warn = snmp_get(base + ".8." + idx)
    dev_lower_crit = snmp_get(base + ".9." + idx)
    if dev_status == "":
        return {"changed": False, "msg": "could not read fan status for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_map = {"1": 1, "2": 3, "3": 0, "4": 1, "5": 2, "6": 2, "7": 1, "8": 2, "9": 2, "10": 2}
    status_desc = {"1": "other", "2": "unknown", "3": "OK", "4": "non critical upper", "5": "critical upper", "6": "non recoverable upper", "7": "non critical lower", "8": "critical lower", "9": "non recoverable lower", "10": "failed"}
    state_code = status_map.get(dev_status, 3)
    status_text = status_desc.get(dev_status, "unknown[" + dev_status + "]")
    summary = "Status: " + status_text

    value = None
    if dev_value != "" and dev_value != "-99":
        v = dev_value.replace(".", "", 1) if dev_value.startswith("-") else dev_value.replace(".", "", 0)
        # Simple float validation: allow digits and one dot
        cleaned = dev_value.lstrip("-")
        if cleaned.replace(".", "", 1).isdigit():
            value = float(dev_value)

    if value == None or dev_value == "-99":
        return {"changed": False, "msg": summary, "data": {"state": _state_name(state_code), "metrics": {}, "details": ""}}

    def validate_levels(dev_warn, dev_crit):
        crit = None
        warn = None
        if dev_crit != "" and dev_crit != "-99":
            crit = float(dev_crit)
        if dev_warn != "" and dev_warn != "-99":
            warn = float(dev_warn)
        elif crit != None:
            warn = crit
        return warn, crit

    upper_warn, upper_crit = validate_levels(dev_upper_warn, dev_upper_crit)
    lower_warn, lower_crit = validate_levels(dev_lower_warn, dev_lower_crit)
    upper_levels = params.get("upper", (upper_warn, upper_crit))
    warn = upper_levels[0] if upper_levels != None else upper_warn
    crit = upper_levels[1] if upper_levels != None else upper_crit

    if warn != None and value >= warn:
        if crit != None and value >= crit:
            state_code = 2
        else:
            state_code = 1
    elif lower_warn != None and value <= lower_warn:
        if lower_crit != None and value <= lower_crit:
            state_code = 2
        else:
            state_code = 1

    return {"changed": False, "msg": item + ": " + summary, "data": {"state": _state_name(state_code), "metrics": {"fan": value}, "details": ""}}


def _state_name(code):
    if code == 0:
        return "OK"
    if code == 1:
        return "WARN"
    if code == 2:
        return "CRIT"
    return "UNKNOWN"