def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: a Stormshield device responds to the
        # enterprise sysObjectID and the Basic Info OID (.1.3.6.1.4.1.11256.1.0.1.0).
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        sysid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid.rc == 127:
            return {"changed": False, "msg": "snmpget not installed", "data": {"discovery": []}}
        if sysid.rc != 0 or not sysid.stdout.strip():
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": []}}

        basic = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.11256.1.0.1.0"],
            mutates=False,
        )
        if basic.rc != 0 or not basic.stdout.strip():
            return {"changed": False, "msg": "not a Stormshield device", "data": {"discovery": []}}

        # Walk the interface table columns (-Oqn: bare "<oid>.<index> <value>").
        cols = {
            "description": "2",
            "name": "3",
            "iftype": "6",
            "pktaccepted": "11",
            "pktblocked": "12",
            "pkticmp": "16",
            "tcp": "23",
            "udp": "24",
        }
        base = ".1.3.6.1.4.1.11256.1.4.1.1"
        by_index = {}
        indices = []

        for field in cols:
            walk = ctx.run(
                ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + cols[field]],
                mutates=False,
            )
            if walk.rc != 0:
                continue
            col_oid = base + "." + cols[field]
            for line in walk.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid, val = parts
                if not oid.startswith(col_oid + "."):
                    continue
                idx = oid[len(col_oid) + 1:]
                if idx not in by_index:
                    by_index[idx] = {}
                    indices.append(idx)
                by_index[idx][field] = val

        discovery = []
        for idx in indices:
            row = by_index[idx]
            iftype = row.get("iftype", "")
            if iftype.lower() in ["ethernet", "ipsec"]:
                desc = row.get("description", "")
                if desc == "":
                    continue
                discovery.append({
                    "item": desc,
                    "params": {},
                    "metrics": ["tcp_active_sessions", "udp_active_sessions",
                                "packages_accepted", "packages_blocked", "packages_icmp_total"],
                })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sysid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysid.rc == 127:
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sysid.rc != 0 or not sysid.stdout.strip():
        return {"changed": False, "msg": "no SNMP response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    basic = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.11256.1.0.1.0"],
        mutates=False,
    )
    if basic.rc != 0 or not basic.stdout.strip():
        return {"changed": False, "msg": "not a Stormshield device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base = ".1.3.6.1.4.1.11256.1.4.1.1"
    cols = {
        "description": "2", "name": "3", "iftype": "6",
        "pktaccepted": "11", "pktblocked": "12", "pkticmp": "16",
        "tcp": "23", "udp": "24",
    }

    # Find the index whose description matches the item.
    desc_walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + cols["description"]],
        mutates=False,
    )
    target_idx = ""
    if desc_walk.rc == 0:
        col_oid = base + "." + cols["description"]
        for line in desc_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts
            if not oid.startswith(col_oid + "."):
                continue
            idx = oid[len(col_oid) + 1:]
            # Strip surrounding quotes if present.
            cleaned = val.strip()
            if cleaned.startswith('"') and cleaned.endswith('"'):
                cleaned = cleaned[1:-1]
            if cleaned == item:
                target_idx = idx
                break

    if target_idx == "":
        return {"changed": False, "msg": "no matching interface: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    row = {}
    for field in cols:
        g = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + cols[field] + "." + target_idx],
            mutates=False,
        )
        row[field] = g.stdout.strip() if g.rc == 0 else ""

    iftype = row.get("iftype", "")
    if iftype.lower() not in ["ethernet", "ipsec"]:
        return {"changed": False, "msg": "interface %s not monitored (iftype=%s)" % (item, iftype),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def _to_int(v):
        cleaned = v.strip()
        if cleaned == "" or cleaned.lower() == "no":
            return 0
        if cleaned.isdigit():
            return int(cleaned)
        return 0

    tcp = _to_int(row.get("tcp", "0"))
    udp = _to_int(row.get("udp", "0"))
    pktaccepted = _to_int(row.get("pktaccepted", "0"))
    pktblocked = _to_int(row.get("pktblocked", "0"))
    pkticmp = _to_int(row.get("pkticmp", "0"))

    name = row.get("name", item)
    infotext = "[%s], tcp: %d, udp: %d" % (name, tcp, udp)

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": "OK",
            "metrics": {
                "tcp_active_sessions": float(tcp),
                "udp_active_sessions": float(udp),
                "packages_accepted": float(pktaccepted),
                "packages_blocked": float(pktblocked),
                "packages_icmp_total": float(pkticmp),
            },
            "details": "",
        },
    }