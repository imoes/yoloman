def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe the real thing: CISCO-PROCESS-MIB / system description must be a Cisco ASA
    sysdesc = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if sysdesc.rc != 0 or sysdesc.stdout == "":
        if params.get("_discover"):
            return {"changed": False, "msg": "no device reachable", "data": {"discovery": []}}
        return {"changed": False, "msg": "no Cisco ASA reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sd = sysdesc.stdout.strip()
    if not (sd.startswith("cisco adaptive security") or sd.startswith("cisco firewall services") or sd.find("cisco pix security") != -1):
        if params.get("_discover"):
            return {"changed": False, "msg": "host is not a Cisco ASA", "data": {"discovery": []}}
        return {"changed": False, "msg": "host is not a Cisco ASA", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch IF-MIB::ifName table: .1.3.6.1.2.1.31.1.1.1.<col>.<ifindex>
    # col 1 = ifName
    ifname_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.31.1.1.1.1"], mutates=False)
    # Fetch IP-MIB::ipAdEntIfIndex / ipAdEntAddr: .1.3.6.1.2.1.4.20.1.<col>.<ip>
    # col 1 = ipAdEntAddr, col 2 = ipAdEntIfIndex
    ip_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.4.20.1.1"], mutates=False)
    ipif_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.4.20.1.2"], mutates=False)
    # Fetch IF-MIB::ifAdminStatus / ifOperStatus: .1.3.6.1.2.1.2.2.1.<col>.<ifindex>
    # col 7 = ifAdminStatus, col 8 = ifOperStatus
    admin_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.2.2.1.7"], mutates=False)
    oper_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.2.2.1.8"], mutates=False)

    # Build interface map: ifindex -> {name, ip, admin, oper}
    interfaces = {}

    # Parse ifName: OID suffix after col base is the ifindex
    col_base_ifname = ".1.3.6.1.2.1.31.1.1.1.1"
    for line in ifname_walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        idx = line_oid[len(col_base_ifname) + 1:]
        val = line[sp + 1:].strip().strip('"')
        if idx == "":
            continue
        d = interfaces.get(idx, {})
        d["name"] = val
        interfaces[idx] = d

    # Parse ipAdEntAddr and ipAdEntIfIndex: OID suffix is the IP address
    col_base_ipaddr = ".1.3.6.1.2.1.4.20.1.1"
    col_base_ipif = ".1.3.6.1.2.1.4.20.1.2"
    ip_to_if = {}
    for line in ip_walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        ip_suffix = line_oid[len(col_base_ipaddr) + 1:]
        val = line[sp + 1:].strip().strip('"')
        if ip_suffix == "":
            continue
        ip_to_if[ip_suffix] = val
    for line in ipif_walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        ip_suffix = line_oid[len(col_base_ipif) + 1:]
        val = line[sp + 1:].strip()
        if ip_suffix == "" or ip_suffix not in ip_to_if:
            continue
        idx = ip_to_if[ip_suffix]
        d = interfaces.get(idx, {})
        d["ip"] = val
        if d.get("name") == None and d.get("admin") == None:
            d["admin"] = "1"
        interfaces[idx] = d

    # Parse admin/oper status: OID suffix is the ifindex
    col_base_admin = ".1.3.6.1.2.1.2.2.1.7"
    col_base_oper = ".1.3.6.1.2.1.2.2.1.8"
    for line in admin_walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        idx = line_oid[len(col_base_admin) + 1:]
        val = line[sp + 1:].strip()
        if idx == "":
            continue
        d = interfaces.get(idx, {})
        d["admin"] = val
        interfaces[idx] = d
    for line in oper_walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        idx = line_oid[len(col_base_oper) + 1:]
        val = line[sp + 1:].strip()
        if idx == "":
            continue
        d = interfaces.get(idx, {})
        d["oper"] = val
        interfaces[idx] = d

    # Discovery mode
    if params.get("_discover"):
        discovery = []
        for if_index, if_data in interfaces.items():
            admin = if_data.get("admin")
            ip = if_data.get("ip")
            if admin == "1" and ip != None:
                discovery.append({"item": if_index, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    # Check mode for a single item
    item = params.get("item", "")
    if_data = interfaces.get(item)

    translate_oper_status = {
        "1": "up",
        "2": "down",
        "3": "testing",
        "4": "unknown",
        "5": "dormant",
        "6": "not present",
        "7": "lower layer down",
    }
    oper_state = {
        "1": "OK",
        "2": "CRIT",
        "3": "UNKNOWN",
        "4": "UNKNOWN",
        "5": "CRIT",
        "6": "CRIT",
        "7": "CRIT",
    }

    if if_data == None:
        return {"changed": False, "msg": "no such interface: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name = if_data.get("name")
    ip = if_data.get("ip")
    oper = if_data.get("oper")

    summary_parts = []
    state = "OK"

    if name:
        summary_parts.append("Name: " + name)

    if ip:
        if name:
            summary_parts.append("IP: " + ip)
        else:
            summary_parts.append("IP: " + ip + " - No network device associated")
            state = "UNKNOWN"
    else:
        summary_parts.append("IP: Not found!")
        state = "CRIT"

    if oper:
        s = oper_state.get(oper, "UNKNOWN")
        readable = translate_oper_status.get(oper, "N/A")
        summary_parts.append("Status: " + readable)
        if s == "CRIT":
            state = "CRIT"
        elif s == "UNKNOWN" and state == "OK":
            state = "UNKNOWN"

    msg = ", ".join(summary_parts)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {}, "details": ""}}