def main(ctx, params):
    if params.get("_discover"):
        # SNMP discovery: walk the power device OID section
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.25506.8.35.9.1.2.1"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }
        # Parse output lines like: ".1.3.6.1.4.1.25506.8.35.9.1.2.1.1 = INTEGER: 1"
        # We only need the last OID segment (item) and the integer value
        items = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if not stripped or "=" not in stripped:
                continue
            parts = stripped.split("=", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract the last OID component (e.g. "1" from ".1.3.6.1.4.1.25506.8.35.9.1.2.1.1")
            last_seg = oid_part.rsplit(".", 1)
            if len(last_seg) != 2:
                continue
            item = last_seg[1]
            # Parse status value: expect "INTEGER: N" or just "N"
            if value_part.startswith("INTEGER: "):
                status_str = value_part[len("INTEGER: "):].strip()
            else:
                status_str = value_part
            if not status_str.isdigit():
                continue
            status = int(status_str)
            # Only include if not UNSUPPORTED (4) or NOT_INSTALLED (3)
            if status not in (4, 3):
                items.append({"item": item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d power devices" % len(items),
            "data": {"discovery": items}
        }

    # Normal check mode: verify one item's status
    item = params.get("item", "")
    # Reuse the same SNMP walk to fetch current status for the item
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.25506.8.35.9.1.2.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    # Find the specific item line
    status = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped or "=" not in stripped:
            continue
        parts = stripped.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Extract the last OID component
        last_seg = oid_part.rsplit(".", 1)
        if len(last_seg) != 2 or last_seg[1] != item:
            continue
        # Parse value
        if value_part.startswith("INTEGER: "):
            status_str = value_part[len("INTEGER: "):].strip()
        else:
            status_str = value_part
        if status_str.isdigit():
            status = int(status_str)
        break

    if status == None:
        return {
            "changed": False,
            "msg": "power device %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    # Status mapping: 1=ACTIVE (OK), 2=DEACTIVE (CRIT), 3=NOT_INSTALLED, 4=UNSUPPORTED
    if status == 2:
        return {
            "changed": False,
            "msg": "Status: deactive",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
    return {
        "changed": False,
        "msg": "Status: active",
        "data": {"state": "OK", "metrics": {}, "details": ""}
    }