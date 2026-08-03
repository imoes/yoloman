def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk the four Rittal CMCTC temp tables via SNMP,
        # keep only temperature sensors (type 10), enumerate items.
        # Each item is "<table>.<index>"; metrics match check_temperature output.
        oid_bases = [
            ".1.3.6.1.4.1.2606.4.2.3.5.2.1",
            ".1.3.6.1.4.1.2606.4.2.4.5.2.1",
            ".1.3.6.1.4.1.2606.4.2.5.5.2.1",
            ".1.3.6.1.4.1.2606.4.2.6.5.2.1",
        ]
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        table_numbers = ["3", "4", "5", "6"]
        items = []
        for tnum, base in zip(table_numbers, oid_bases):
            res = ctx.run(
                ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1"],
                mutates=False,
            )
            if res.rc != 0 or not res.stdout:
                continue
            seen = {}
            for line in res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                value = parts[1]
                suffix = oid[len(base) + 1:]
                fields = suffix.split(".")
                if len(fields) < 1:
                    continue
                idx = fields[0]
                col = fields[1] if len(fields) > 1 else ""
                entry = seen.get(idx, {})
                if col == "2":
                    entry["type"] = value
                elif col == "1":
                    entry["index"] = value
                elif col == "3":
                    entry["status"] = value
                elif col == "4":
                    entry["reading"] = value
                elif col == "5":
                    entry["crit"] = value
                elif col == "6":
                    entry["low"] = value
                elif col == "7":
                    entry["warn"] = value
                elif col == "8":
                    entry["desc"] = value
                seen[idx] = entry
            for idx, e in seen.items():
                if e.get("type") == "10":
                    items.append({
                        "item": tnum + "." + idx,
                        "params": {"levels": (params.get("warn", 0), params.get("crit", 0))},
                        "metrics": ["temperature"],
                    })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items},
            "service_labels": {},
        }

    # Check mode (read-only) for a single item
    item = params.get("item", "")
    warn = params.get("warn", 0)
    crit = params.get("crit", 0)
    # Checkmk levels come as (warn, crit) tuple for "temperature" ruleset
    lvls = params.get("levels", (warn, crit))
    if lvls != None and type(lvls) == "list" and len(lvls) >= 2:
        warn = lvls[0]
        crit = lvls[1]
    elif lvls != None and type(lvls) == "tuple" and len(lvls) >= 2:
        warn = lvls[0]
        crit = lvls[1]

    if "." not in item:
        return {
            "changed": False,
            "msg": "invalid item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no temperature sensor found"},
        }
    tnum = item.split(".", 1)[0]
    idx = item.split(".", 1)[1]
    oid_bases = {
        "3": ".1.3.6.1.4.1.2606.4.2.3.5.2.1",
        "4": ".1.3.6.1.4.1.2606.4.2.4.5.2.1",
        "5": ".1.3.6.1.4.1.2606.4.2.5.5.2.1",
        "6": ".1.3.6.1.4.1.2606.4.2.6.5.2.1",
    }
    base = oid_bases.get(tnum)
    if base == None:
        return {
            "changed": False,
            "msg": "invalid table: %s" % tnum,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no temperature sensor found"},
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    # Read columns 2 (type), 3 (status), 4 (reading), 5 (crit), 6 (warnlow), 7 (warn), 8 (desc)
    cols = {"2": "type", "3": "status", "4": "reading", "5": "crit", "6": "low", "7": "warn", "8": "desc"}
    row = {}
    for col in ["2", "3", "4", "5", "6", "7", "8"]:
        oid = base + "." + col + "." + idx
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if res.rc != 0 or not res.stdout:
            # Missing sensor -> UNKNOWN
            return {
                "changed": False,
                "msg": "no temperature sensor: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no temperature sensor found"},
            }
        row[cols[col]] = res.stdout.strip()

    if row.get("type") != "10":
        return {
            "changed": False,
            "msg": "not a temperature sensor: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no temperature sensor found"},
        }

    reading = 0
    if row.get("reading") != None and row.get("reading").lstrip("-").isdigit():
        reading = int(row.get("reading"))

    # Device status translation (Rittal CMCTC)
    status_map = {4: 0, 7: 1, 8: 1, 9: 2}
    status_text_map = {
        1: "notAvail", 2: "lost", 3: "changed", 4: "ok", 5: "off",
        6: "on", 7: "warning", 8: "tooLow", 9: "tooHigh",
    }
    st_val = int(row.get("status")) if row.get("status") != None and row.get("status").isdigit() else 0
    dev_status = status_map.get(st_val, 3)
    dev_status_name = "Unit: " + status_text_map.get(st_val, "UNKNOWN")

    # Apply device levels: reading >= crit -> CRIT, >= warn -> WARN (upper); < low -> CRIT
    state = "OK"
    if dev_status == 2:
        state = "CRIT"
    elif dev_status == 1:
        state = "WARN"
    else:
        w = float(row.get("warn")) if row.get("warn") != None else float(warn)
        c = float(row.get("crit")) if row.get("crit") != None else float(crit)
        if reading >= c:
            state = "CRIT"
        elif reading >= w:
            state = "WARN"

    msg = "%s" % reading
    details = dev_status_name + "\nSensor: " + item
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {"temperature": reading}, "details": details},
    }