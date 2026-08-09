def main(ctx, params):
    if params.get("_discover"):
        # Probe for FortiMail device via sysObjectID
        sys_oid = ".1.3.6.1.2.1.1.2.0"
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), sys_oid],
            mutates=False)
        if sys_res.rc != 0:
            return {"changed": False, "msg": "FortiMail not found (SNMP not reachable)",
                    "data": {"discovery": []}}

        expected_sysid = ".1.3.6.1.4.1.12356.105"
        is_fortimail = sys_res.stdout.strip() == expected_sysid
        if not is_fortimail:
            return {"changed": False, "msg": "not a FortiMail device",
                    "data": {"discovery": []}}

        # Walk the queue name column (OID .2) to discover queues
        name_oid = ".1.3.6.1.4.1.12356.105.1.103.2.1.2"
        walk_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), name_oid],
            mutates=False)
        if walk_res.rc != 0:
            return {"changed": False, "msg": "FortiMail queue table not accessible",
                    "data": {"discovery": []}}

        discovery = []
        for line in walk_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            full_oid = parts[0]
            queue_name = parts[1].strip().strip('"')
            # index is the OID suffix after the column base
            index = full_oid[len(name_oid) + 1:]
            discovery.append({
                "item": queue_name,
                "params": {"queue_length": (100, 200)},
                "metrics": ["mail_queue_active_length", "mail_queue_active_size"],
            })

        return {"changed": False,
                "msg": "discovered %d mail queues" % len(discovery),
                "data": {"discovery": discovery}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    name_oid = ".1.3.6.1.4.1.12356.105.1.103.2.1.2"
    count_oid = ".1.3.6.1.4.1.12356.105.1.103.2.1.3"
    size_oid = ".1.3.6.1.4.1.12356.105.1.103.2.1.4"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Find the index for this queue by walking the name column
    walk_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, name_oid],
        mutates=False)
    if walk_res.rc != 0:
        return {"changed": False, "msg": "no mail queues found (SNMP walk failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_index = None
    for line in walk_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        full_oid = parts[0]
        queue_name = parts[1].strip().strip('"')
        if queue_name == item:
            target_index = full_oid[len(name_oid) + 1:]
            break

    if target_index == None:
        return {"changed": False, "msg": "queue not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch count and size by index
    count_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, count_oid + "." + target_index],
        mutates=False)
    size_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, size_oid + "." + target_index],
        mutates=False)

    if count_res.rc != 0 or size_res.rc != 0:
        return {"changed": False, "msg": "failed to fetch queue data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    count_str = count_res.stdout.strip()
    size_str = size_res.stdout.strip()

    # Guard against non-numeric output
    count = int(count_str) if count_str.isdigit() else 0
    size_kb = int(size_str) if size_str.isdigit() else 0
    size_bytes = size_kb * 1024

    # Thresholds
    levels = params.get("queue_length", (100, 200))
    warn = levels[0] if levels else 100
    crit = levels[1] if levels else 200

    # Grade length (upper levels: WARN if >= warn, CRIT if >= crit)
    state = "OK"
    if count >= crit:
        state = "CRIT"
    elif count >= warn:
        state = "WARN"

    # Format size for display
    if size_bytes >= 1048576:
        size_disp = "%f MB" % (size_bytes / 1048576.0)
    elif size_bytes >= 1024:
        size_disp = "%f KB" % (size_bytes / 1024.0)
    else:
        size_disp = "%d B" % size_bytes

    msg = "%s: length %d, size %s" % (item, count, size_disp)
    details = "Length: %d (warn: %d, crit: %d)" % (count, warn, crit)

    return {"changed": False, "msg": msg,
            "data": {
                "state": state,
                "metrics": {
                    "mail_queue_active_length": count,
                    "mail_queue_active_size": size_bytes,
                },
                "details": details,
            }}