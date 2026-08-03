def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")

    # Probe for Check Point via sysDescr (detection).
    descr = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.2.1.1.1.0",
    ], mutates=False)
    if descr.rc != 0 or not descr.stdout:
        return {"changed": False, "msg": "no SNMP response (not a Check Point device)",
                "data": {"discovery": [], "host_labels": {}}}

    sys_oid = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.2.1.1.2.0",
    ], mutates=False)
    sys_oid_val = sys_oid.stdout.strip()

    fw = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.4.1.2620.1.1.21.0",
    ], mutates=False)
    fw_val = fw.stdout.strip() if fw.rc == 0 else ""

    gaia = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.4.1.2620.1.6.5.1.0",
    ], mutates=False)
    gaia_val = gaia.stdout.strip() if gaia.rc == 0 else ""

    sys_match = (
        sys_oid_val.startswith(".1.3.6.1.4.1.2620")
        or descr.stdout.startswith("IPSO ")
        or (descr.stdout.find("cp") != -1 and descr.stdout.find("cp") < 40)
        or descr.stdout.startswith("Linux") and descr.stdout.find("cpx") != -1
    )
    fw_match = fw_val.startswith("firewall")
    gaia_match = gaia_val == "Gaia"

    if not (sys_match and (fw_match or gaia_match)):
        return {"changed": False, "msg": "not a Check Point device",
                "data": {"discovery": [], "host_labels": {"cmk/checkpoint_detected": "false"}}}

    # Fetch the fan table: name(.2), value(.3), unit(.4), status(.6)
    names = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host,
        ".1.3.6.1.4.1.2620.1.6.7.8.2.1.2",
    ], mutates=False)
    values = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host,
        ".1.3.6.1.4.1.2620.1.6.7.8.2.1.3",
    ], mutates=False)
    units = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host,
        ".1.3.6.1.4.1.2620.1.6.7.8.2.1.4",
    ], mutates=False)
    statuses = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host,
        ".1.3.6.1.4.1.2620.1.6.7.8.2.1.6",
    ], mutates=False)

    if names.rc != 0:
        return {"changed": False, "msg": "no fan data available",
                "data": {"discovery": [], "host_labels": {}}}

    def _parse_rows(res):
        rows = {}
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            idx = oid[len(".1.3.6.1.4.1.2620.1.6.7.8.2.1"):].lstrip(".")
            rows[idx] = val
        return rows

    name_map = _parse_rows(names)
    value_map = _parse_rows(values)
    unit_map = _parse_rows(units)
    status_map = _parse_rows(statuses)

    if params.get("_discover"):
        discovery = []
        for idx in sorted(name_map.keys()):
            nm = name_map[idx]
            fan_item = nm.replace(" Fan", "")
            discovery.append({
                "item": fan_item,
                "params": {},
                "metrics": [],
                "service_labels": {"checkpoint.fan.unit": unit_map.get(idx, "")},
            })
        return {"changed": False,
                "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}

    # Check mode: find the requested item.
    target_idx = None
    for idx in sorted(name_map.keys()):
        nm = name_map[idx]
        fan_item = nm.replace(" Fan", "")
        if fan_item == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False, "msg": "fan not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    dev_status = status_map.get(target_idx, "")
    state_map = {"0": ("OK", "sensor in range"), "1": ("CRIT", "sensor out of range"),
                 "2": ("UNKNOWN", "reading error")}
    if dev_status in state_map:
        state, readable = state_map[dev_status]
    else:
        state, readable = "UNKNOWN", "unknown status: " + dev_status

    val = value_map.get(target_idx, "")
    unit = unit_map.get(target_idx, "")
    summary = "Status: %s, %s %s" % (readable, val, unit)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}