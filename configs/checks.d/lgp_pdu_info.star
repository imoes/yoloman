def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for LGP device by checking sysObjectID
    sysid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )

    # rc == 127 means snmpget not installed / unreachable
    if sysid_res.rc == 127:
        return {"changed": False, "msg": "device not present", "data": {"discovery": []}}

    is_lgp = False
    if sysid_res.rc == 0:
        sysid = sysid_res.stdout.strip()
        is_lgp = sysid == ".1.3.6.1.4.1.476.1.42"

    if not is_lgp:
        return {"changed": False, "msg": "device not present", "data": {"discovery": []}}

    # Column OIDs under base .1.3.6.1.4.1.476.1.42.3.8.20.1
    base = ".1.3.6.1.4.1.476.1.42.3.8.20.1"
    oid_entry = base + ".5"
    oid_label = base + ".10"
    oid_sys_label = base + ".15"
    oid_serial = base + ".45"
    oid_num_rcs = base + ".50"

    # Walk all columns with -Oqn for clean numeric OID output
    col_oids = [oid_entry, oid_label, oid_sys_label, oid_serial, oid_num_rcs]

    # Gather all table rows by index
    pdus = {}
    for col_oid in col_oids:
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
            mutates=False,
        )
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            # line format: "<full_oid> <value>"
            space_idx = line.find(" ")
            if space_idx == -1:
                continue
            line_oid = line[:space_idx]
            val = line[space_idx + 1:]
            # index is the suffix after the column OID
            if line_oid.startswith(col_oid + "."):
                index = line_oid[len(col_oid) + 1:]
                if index not in pdus:
                    pdus[index] = {}
                # Map column to position: entry=0, label=1, sys_label=2, serial=3, num_rcs=4
                col_idx = col_oids.index(col_oid)
                pdus[index][col_idx] = val

    # Build ordered rows
    rows = []
    for index in sorted(pdus.keys()):
        cols = pdus[index]
        if len(cols) < 5:
            continue
        entry_id = cols.get(0, "")
        label = cols.get(1, "")
        sys_label = cols.get(2, "")
        serial = cols.get(3, "")
        num_rcs = cols.get(4, "")
        rows.append([entry_id, label, sys_label, serial, num_rcs])

    if params.get("_discover"):
        discovery = []
        for row in rows:
            discovery.append({
                "item": row[2],
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode: find the item
    item = params.get("item", "")
    for row in rows:
        if row[2] == item:
            entry_id, label, sys_label, serial, num_rcs = row
            msg = "Entry-ID: %s, Label: %s (%s), S/N: %s, Num. RCs: %s" % (
                entry_id, label, sys_label, serial, num_rcs,
            )
            return {
                "changed": False,
                "msg": msg,
                "data": {
                    "state": "OK",
                    "metrics": {},
                    "details": "",
                },
            }

    return {
        "changed": False,
        "msg": "Device can not be found in SNMP output.",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }