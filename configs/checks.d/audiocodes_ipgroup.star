_READABLE_STATUS = {
    "1": "active",
    "2": "notInService",
    "3": "notReady",
}

_READABLE_TYPE = {
    "0": "Server",
    "1": "User",
    "2": "Gateway",
}

_BASE_ATTR = ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1"
_BASE_CALLS = ".1.3.6.1.4.1.5003.15.3.1.1.2.1.1"


def _snmp_walk(ctx, community, host, oid):
    return ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )


def _parse_attributes(fields):
    index = int(fields[0])
    status = _READABLE_STATUS.get(fields[1], fields[1])
    ipgroup_type = _READABLE_TYPE.get(fields[2], fields[2])
    description = fields[3] if fields[3] else None
    name = fields[4]
    connect_status = fields[5]
    return {
        "index": index,
        "status": status,
        "type": ipgroup_type,
        "description": description,
        "name": name,
        "connect_status": connect_status,
    }


def _load_ipgroups(ctx, community, host):
    res = _snmp_walk(ctx, community, host, _BASE_ATTR + ".1")
    if res.rc != 0:
        return {}
    attr_lines = res.stdout.splitlines()

    res_calls = _snmp_walk(ctx, community, host, _BASE_CALLS + ".3")
    calls_lines = res_calls.stdout.splitlines() if res_calls.rc == 0 else []

    res_calls_out = _snmp_walk(ctx, community, host, _BASE_CALLS + ".4")
    calls_out_lines = res_calls_out.stdout.splitlines() if res_calls_out.rc == 0 else []

    attrs_by_index = {}
    for line in attr_lines:
        parts = line.split()
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = " ".join(parts[1:])
        index_suffix = oid[len(_BASE_ATTR) + 2:]
        col = oid[len(_BASE_ATTR) + 1 : len(_BASE_ATTR) + 2]
        row = attrs_by_index.setdefault(index_suffix, {})
        row[col] = value

    ipgroups = {}
    for index_suffix, cols in attrs_by_index.items():
        f = [
            cols.get("1", ""),
            cols.get("2", ""),
            cols.get("5", ""),
            cols.get("6", ""),
            cols.get("31", ""),
            cols.get("36", ""),
        ]
        if not f[4]:
            continue
        attr = _parse_attributes(f)
        ipgroups[str(attr["index"]) + " " + attr["name"]] = {
            "attributes": attr,
            "calls_in": None,
            "calls_out": None,
        }

    calls_in_by_index = {}
    for line in calls_lines:
        parts = line.split()
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1]
        index_suffix = oid[len(_BASE_CALLS + ".3") + 1:]
        calls_in_by_index[index_suffix] = value

    calls_out_by_index = {}
    for line in calls_out_lines:
        parts = line.split()
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1]
        index_suffix = oid[len(_BASE_CALLS + ".4") + 1:]
        calls_out_by_index[index_suffix] = value

    for key, group in ipgroups.items():
        idx = str(group["attributes"]["index"])
        ci = calls_in_by_index.get(idx)
        co = calls_out_by_index.get(idx)
        if ci != None and ci.isdigit():
            group["calls_in"] = int(ci)
        if co != None and co.isdigit():
            group["calls_out"] = int(co)

    return ipgroups


def _grade_state(attr):
    status = attr["status"]
    connect_status = attr["connect_status"]
    if status == "active" and connect_status in ("Connected", "NA"):
        return "OK"
    return "CRIT"


def _fmt_details(attr):
    desc = attr["description"]
    if desc == None:
        desc_str = "None"
    else:
        desc_str = desc
    return "IP group name: %s, Type: %s, IP group index: %d, Description: %s, Proxy set connectivity: %s" % (
        attr["name"],
        attr["type"],
        attr["index"],
        desc_str,
        attr["connect_status"],
    )


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        groups = _load_ipgroups(ctx, community, host)
        discovery = []
        for item_name in sorted(groups.keys()):
            discovery.append({
                "item": item_name,
                "params": {},
                "metrics": [
                    "audiocodes_ipgroup_active_calls_in",
                    "audiocodes_ipgroup_active_calls_out",
                ],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    groups = _load_ipgroups(ctx, community, host)

    if item not in groups:
        return {
            "changed": False,
            "msg": "no such IP group: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    group = groups[item]
    attr = group["attributes"]
    state = _grade_state(attr)

    metrics = {}
    if group["calls_in"] != None:
        metrics["audiocodes_ipgroup_active_calls_in"] = group["calls_in"]
    if group["calls_out"] != None:
        metrics["audiocodes_ipgroup_active_calls_out"] = group["calls_out"]

    details = _fmt_details(attr)
    summary = "Status: %s" % attr["status"]
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }