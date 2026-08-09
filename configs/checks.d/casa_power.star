def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Probe for the CASA device (DETECT_CASA: sysObjectID starts with .1.3.6.1.4.1.20858.2.)
    sysid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysid_res.rc != 0 or not sysid_res.stdout:
        return {"changed": False, "msg": "no casa device found",
                "data": {"discovery": []}}
    sysid = sysid_res.stdout.strip()
    if not sysid.startswith(".1.3.6.1.4.1.20858.2."):
        return {"changed": False, "msg": "no casa device found",
                "data": {"discovery": []}}

    # Fetch the power supply table rows (OID .4 under base .1.3.6.1.4.1.20858.10.33.1.5.1)
    walk_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn",
         host, ".1.3.6.1.4.1.20858.10.33.1.5.1.4"],
        mutates=False,
    )

    # Parse: one "<oid>.<idx> <value>" line per row; idx = suffix after the .4 column oid
    statuses = {}
    column_oid = ".1.3.6.1.4.1.20858.10.33.1.5.1.4"
    if walk_res.rc == 0 and walk_res.stdout:
        for line in walk_res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            oid, value = parts[0], parts[1]
            if oid.startswith(column_oid + "."):
                idx = oid[len(column_oid) + 1:]
                if idx.isdigit():
                    statuses[int(idx)] = value

    if params.get("_discover"):
        discovery = []
        for idx in sorted(statuses.keys()):
            discovery.append({
                "item": str(idx),
                "params": {},
                "metrics": [],
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    unit_nr = int(item) if item != "" and item.isdigit() else -1
    if unit_nr not in statuses:
        return {"changed": False,
                "msg": "Power Supply %s not found in snmp output" % str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = statuses[unit_nr]
    verdict = {
        "0": ("UNKNOWN", "Power supply - Unknown status"),
        "1": ("OK", "Power supply OK"),
        "2": ("OK", "Power supply working under threshold"),
        "3": ("WARN", "Power supply working over threshold"),
        "4": ("CRIT", "Power failure"),
    }.get(status)
    if verdict == None:
        return {"changed": False,
                "msg": "Power Supply %s - unknown status %s" % (str(item), status),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state, msg = verdict
    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}