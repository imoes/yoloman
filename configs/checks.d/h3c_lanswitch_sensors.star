def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: H3C/3Com device identified by sysDescr
    detect_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if detect_res.rc != 0 or "3com s" not in detect_res.stdout:
        return {
            "changed": False,
            "msg": "H3C/3Com device not found",
            "data": {"discovery": [], "details": "no 3Com/H3C sysDescr detected"},
        }

    # Fan table: .1.3.6.1.4.1.43.45.1.2.23.1.9.1.1.1 (OIDEnd + status col "2")
    fan_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.43.45.1.2.23.1.9.1.1.1"],
        mutates=False,
    )
    # Power supply table: .1.3.6.1.4.1.43.45.1.2.23.1.9.1.2.1
    psu_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.43.45.1.2.23.1.9.1.2.1"],
        mutates=False,
    )

    if params.get("_discover"):
        section = _build_section(fan_res, psu_res)
        if not section:
            return {"changed": False, "msg": "discovered 0 sensors", "data": {"discovery": []}}
        discovery = []
        for item, state in section.items():
            if state in ["1", "2"]:
                discovery.append({"item": item, "params": {}, "metrics": ["sensor_state"]})
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    section = _build_section(fan_res, psu_res)
    status = section.get(item)
    if status == None:
        return {
            "changed": False,
            "msg": "Sensor %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no data for this item"},
        }

    # values: active (1), deactive (2), not-install (3), unsupport (4)
    if status == "2":
        state = "CRIT"
    elif status == "1":
        state = "OK"
    else:
        state = "WARN"
    return {
        "changed": False,
        "msg": "Sensor %s status is %s" % (item, status),
        "data": {"state": state, "metrics": {"sensor_state": _to_int(status)}, "details": ""},
    }


def _to_int(s):
    return int(s) if s.isdigit() else 0


def _genitem(device_class, id_):
    num_id = int(id_) if id_.isdigit() else 0
    unitid = num_id // 65536
    num = num_id % 65536
    return "Unit %d %s %d" % (unitid, device_class, num)


def _parse_table(res, base_oid, device_class):
    out = {}
    if res.rc != 0 or not res.stdout:
        return out
    base_len = len(base_oid)
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        val = parts[1].strip()
        if not oid.startswith(base_oid + "."):
            continue
        index = oid[base_len + 1:]
        if not index.isdigit():
            continue
        item = _genitem(device_class, index)
        out[item] = val
    return out


def _build_section(fan_res, psu_res):
    section = {}
    fan_base = ".1.3.6.1.4.1.43.45.1.2.23.1.9.1.1.1"
    psu_base = ".1.3.6.1.4.1.43.45.1.2.23.1.9.1.2.1"
    section.update(_parse_table(fan_res, fan_base, "Fan"))
    section.update(_parse_table(psu_res, psu_base, "Powersupply"))
    return section