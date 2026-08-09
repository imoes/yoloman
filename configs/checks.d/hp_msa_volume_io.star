def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if out == "":
        return None
    return out

def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        lines.append(line)
    return lines

def _parse_walk_line(line):
    idx = line.find(" ")
    if idx == -1:
        return None, None
    oid = line[:idx]
    value = line[idx + 1:]
    return oid, value

def _discover_volumes(ctx, host, community):
    vol_table_oid = ".1.3.6.1.4.1.2382.1.1.2.2.3.1.2"
    vol_lines = _snmp_walk(ctx, host, community, vol_table_oid)
    volumes = []
    for line in vol_lines:
        oid, name = _parse_walk_line(line)
        if oid == None or name == None:
            continue
        index = oid[len(vol_table_oid) + 1:]
        if index == "":
            continue
        name = name.strip().strip('"')
        volumes.append({"index": index, "name": name})
    return volumes

def _get_volume_io(ctx, host, community, index):
    base = ".1.3.6.1.4.1.2382.1.1.2.2.3.1"
    read_oid = base + ".4." + index
    write_oid = base + ".5." + index
    read_val = _snmp_get(ctx, host, community, read_oid)
    write_val = _snmp_get(ctx, host, community, write_oid)
    read_t = 0
    write_t = 0
    if read_val != None and read_val != "":
        if read_val.lstrip("-").isdigit():
            read_t = int(read_val)
    if write_val != None and write_val != "":
        if write_val.lstrip("-").isdigit():
            write_t = int(write_val)
    return read_t, write_t

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn", 0)
    crit = params.get("crit", 0)
    read_warn = 0
    read_crit = 0
    write_warn = 0
    write_crit = 0
    levels = params.get("levels")
    if levels != None and type(levels) == "list":
        if len(levels) >= 2:
            read_warn = levels[0]
            read_crit = levels[1]
        if len(levels) >= 4:
            write_warn = levels[2]
            write_crit = levels[3]

    if params.get("_discover"):
        probe = _snmp_get(ctx, host, community, ".1.3.6.1.4.1.2382.1.1.2.2.3.1.2")
        if probe == None:
            return {
                "changed": False,
                "msg": "no hp_msa volumes found",
                "data": {"discovery": [], "host_labels": {}},
            }
        volumes = _discover_volumes(ctx, host, community)
        discovery = []
        for v in volumes:
            discovery.append({
                "item": v["name"],
                "params": {"warn": warn, "crit": crit},
                "metrics": ["read_throughput", "write_throughput"],
            })
        return {
            "changed": False,
            "msg": "discovered %d hp_msa volumes" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {"cmk/hp_msa": "yes"}},
        }

    item = params.get("item", "")
    volumes = _discover_volumes(ctx, host, community)
    matched = None
    for v in volumes:
        if v["name"] == item:
            matched = v
            break
    if matched == None:
        return {
            "changed": False,
            "msg": "no hp_msa volume found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    read_t, write_t = _get_volume_io(ctx, host, community, matched["index"])
    state = "OK"
    if read_warn > 0 and read_t >= read_warn:
        state = "WARN"
    if read_crit > 0 and read_t >= read_crit:
        state = "CRIT"
    if write_warn > 0 and write_t >= write_warn and state != "CRIT":
        state = "WARN"
    if write_crit > 0 and write_t >= write_crit:
        state = "CRIT"
    msg = "%s read=%d write=%d" % (item, read_t, write_t)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"read_throughput": read_t, "write_throughput": write_t},
            "details": "",
        },
    }