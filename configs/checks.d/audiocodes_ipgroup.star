_READABLE_STATUS = {"1": "active", "2": "notInService", "3": "notReady"}
_READABLE_TYPE = {"0": "Server", "1": "User", "2": "Gateway"}

def _parse_attributes(info):
    index = int(info[0])
    status = _READABLE_STATUS.get(info[1], info[1])
    ipgroup_type = _READABLE_TYPE.get(info[2], info[2])
    description = info[3] if info[3] != "" else None
    name = info[4]
    connect_status = info[5]
    return {
        "index": index,
        "status": status,
        "type": ipgroup_type,
        "description": description,
        "name": name,
        "connect_status": connect_status,
    }

def _parse_ipgroup(section):
    if not section or not section[0]:
        return None
    attributes_by_index = {}
    for info in section[0]:
        if len(info) < 6:
            continue
        parsed = _parse_attributes(info)
        index = parsed["index"]
        item = "%d %s" % (index, parsed["name"])
        attributes_by_index[item] = parsed
    active_calls_by_index = {}
    if len(section) > 1:
        for row in section[1]:
            if len(row) < 3:
                continue
            end_oid = row[0]
            calls_in = row[1] if row[1] != "" else None
            calls_out = row[2] if row[2] != "" else None
            active_calls_by_index[end_oid] = {
                "calls_in": int(calls_in) if calls_in != None else None,
                "calls_out": int(calls_out) if calls_out != None else None,
            }
    result = {}
    for item, attrs in attributes_by_index.items():
        index = attrs["index"]
        index_str = str(index)
        calls_data = active_calls_by_index.get(index_str, {"calls_in": None, "calls_out": None})
        result[item] = {
            "attributes": attrs,
            "active_calls": calls_data,
        }
    return result

def _check_ipgroup_state(ipgroup_data):
    attrs = ipgroup_data["attributes"]
    if attrs["status"] == "active" and (attrs["connect_status"] == "Connected" or attrs["connect_status"] == "NA"):
        return "OK"
    return "CRIT"

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1"
        ], mutates=False)
        section1 = []
        for line in res.stdout.splitlines():
            if line.strip() == "":
                continue
            parts = line.strip().split(" ")
            if len(parts) < 3:
                continue
            oid_end = parts[0].rsplit(".", 1)[-1]
            value = " ".join(parts[2:]).strip('"')
            section1.append([oid_end, value])
        # Parse multiple columns
        # We need to group by OID index; re-walk per-column to get all six fields
        res1 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.1"
        ], mutates=False)  # index
        res2 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.2"
        ], mutates=False)  # status
        res3 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.5"
        ], mutates=False)  # type
        res4 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.6"
        ], mutates=False)  # description
        res5 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.31"
        ], mutates=False)  # name
        res6 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.36"
        ], mutates=False)  # connect status
        # Map oids to values per column
        def _parse_snmpwalk_output(res):
            result = {}
            for line in res.stdout.splitlines():
                if line.strip() == "":
                    continue
                parts = line.strip().split(" ")
                if len(parts) < 3:
                    continue
                oid = parts[0]
                value = " ".join(parts[2:]).strip('"')
                # Extract leaf
                leaf = oid.rsplit(".", 1)[-1]
                result[leaf] = value
            return result
        index_map = _parse_snmpwalk_output(res1)
        status_map = _parse_snmpwalk_output(res2)
        type_map = _parse_snmpwalk_output(res3)
        desc_map = _parse_snmpwalk_output(res4)
        name_map = _parse_snmpwalk_output(res5)
        conn_map = _parse_snmpwalk_output(res6)
        # Build section data
        section = [[], []]
        for leaf in sorted(index_map.keys(), key=lambda x: int(x)):
            idx = index_map[leaf]
            status = status_map.get(leaf, "")
            type_val = type_map.get(leaf, "")
            desc = desc_map.get(leaf, "")
            name = name_map.get(leaf, "")
            conn = conn_map.get(leaf, "")
            section[0].append([idx, status, type_val, desc, name, conn])
        # Gather active calls data
        res_calls_in = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.15.3.1.1.2.1.1.3"
        ], mutates=False)
        res_calls_out = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.15.3.1.1.2.1.1.4"
        ], mutates=False)
        calls_in_map = _parse_snmpwalk_output(res_calls_in)
        calls_out_map = _parse_snmpwalk_output(res_calls_out)
        for leaf in sorted(index_map.keys(), key=lambda x: int(x)):
            idx = index_map[leaf]
            calls_in = calls_in_map.get(leaf, "")
            calls_out = calls_out_map.get(leaf, "")
            section[1].append([leaf, calls_in, calls_out])
        parsed = _parse_ipgroup(section)
        if parsed == None:
            parsed = {}
        discovery = []
        for item in parsed.keys():
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["audiocodes_ipgroup_active_calls_in", "audiocodes_ipgroup_active_calls_out"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1"
    ], mutates=False)
    res1 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.1"
    ], mutates=False)
    res2 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.2"
    ], mutates=False)
    res3 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.5"
    ], mutates=False)
    res4 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.6"
    ], mutates=False)
    res5 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.31"
    ], mutates=False)
    res6 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.9.10.3.1.1.23.21.1.36"
    ], mutates=False)
    res_calls_in = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.15.3.1.1.2.1.1.3"
    ], mutates=False)
    res_calls_out = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.5003.15.3.1.1.2.1.1.4"
    ], mutates=False)
    def _parse_snmpwalk_output(res):
        result = {}
        for line in res.stdout.splitlines():
            if line.strip() == "":
                continue
            parts = line.strip().split(" ")
            if len(parts) < 3:
                continue
            oid = parts[0]
            value = " ".join(parts[2:]).strip('"')
            leaf = oid.rsplit(".", 1)[-1]
            result[leaf] = value
        return result
    index_map = _parse_snmpwalk_output(res1)
    status_map = _parse_snmpwalk_output(res2)
    type_map = _parse_snmpwalk_output(res3)
    desc_map = _parse_snmpwalk_output(res4)
    name_map = _parse_snmpwalk_output(res5)
    conn_map = _parse_snmpwalk_output(res6)
    calls_in_map = _parse_snmpwalk_output(res_calls_in)
    calls_out_map = _parse_snmpwalk_output(res_calls_out)
    # Build section data
    section = [[], []]
    for leaf in sorted(index_map.keys(), key=lambda x: int(x)):
        idx = index_map[leaf]
        status = status_map.get(leaf, "")
        type_val = type_map.get(leaf, "")
        desc = desc_map.get(leaf, "")
        name = name_map.get(leaf, "")
        conn = conn_map.get(leaf, "")
        section[0].append([idx, status, type_val, desc, name, conn])
    for leaf in sorted(index_map.keys(), key=lambda x: int(x)):
        idx = index_map[leaf]
        calls_in = calls_in_map.get(leaf, "")
        calls_out = calls_out_map.get(leaf, "")
        section[1].append([leaf, calls_in, calls_out])
    parsed = _parse_ipgroup(section)
    if parsed == None:
        parsed = {}
    if item not in parsed:
        return {
            "changed": False,
            "msg": "IP group not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    ipgroup = parsed[item]
    attrs = ipgroup["attributes"]
    calls_data = ipgroup["active_calls"]
    state = _check_ipgroup_state(ipgroup)
    summary = "Status: " + attrs["status"]
    details = (
        "IP group name: %s, Type: %s, IP group index: %d, " +
        "Description: %s, Proxy set connectivity: %s"
    ) % (
        attrs["name"],
        attrs["type"],
        attrs["index"],
        attrs["description"] if attrs["description"] != None else "",
        attrs["connect_status"],
    )
    metrics = {}
    if calls_data["calls_in"] != None:
        metrics["audiocodes_ipgroup_active_calls_in"] = calls_data["calls_in"]
    if calls_data["calls_out"] != None:
        metrics["audiocodes_ipgroup_active_calls_out"] = calls_data["calls_out"]
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }