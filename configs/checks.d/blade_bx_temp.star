def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            [
                "snmpwalk",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqn",
                "-M",
                params.get("host", "localhost"),
                ".1.3.6.1.4.1.7244.1.1.1.3.4.1.1.1",
            ],
            mutates=False,
        )
        # Probe the device presence via the first scalar column status OID
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP unavailable", "data": {"discovery": []}}

        status_map = {}
        for line in res.stdout.splitlines():
            # each line: "<oid> <value>"
            parts = line.split()
            if len(parts) != 2:
                continue
            oid = parts[0]
            # index is the suffix after the column base OID
            base = ".1.3.6.1.4.1.7244.1.1.1.3.4.1.1.1"
            if oid.startswith(base):
                idx = oid[len(base) + 1:]
                # status column is .1 -> value
                status_map[idx] = parts[1]

        # Now fetch description column (.3) to get the item names
        res2 = ctx.run(
            [
                "snmpwalk",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqn",
                "-M",
                params.get("host", "localhost"),
                ".1.3.6.1.4.1.7244.1.1.1.3.4.1.1.3",
            ],
            mutates=False,
        )
        discovery = []
        for line in res2.stdout.splitlines():
            parts = line.split()
            if len(parts) != 2:
                continue
            oid = parts[0]
            base = ".1.3.6.1.4.1.7244.1.1.1.3.4.1.1.3"
            if not oid.startswith(base):
                continue
            idx = oid[len(base) + 1:]
            descr = parts[1].strip("\"")
            status = saveint(status_map.get(idx, "0"))
            # status 7 = "not-available" -> skip
            if status != 7:
                discovery.append(
                    {
                        "item": descr,
                        "params": {"warn": 60, "crit": 80},
                        "metrics": ["temp"],
                    }
                )
        return {
            "changed": False,
            "msg": "discovered %d blades" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.7244.1.1.1.3.4.1.1"
    # Fetch all columns as a table; we need to find the row whose description
    # matches the requested item.
    # Columns: 1=status, 3=descr, 4=warn, 5=crit, 6=temp, 7=crit_react

    def fetch_col(col_oid):
        res = ctx.run(
            [
                "snmpwalk",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqn",
                "-M",
                params.get("host", "localhost"),
                base + "." + col_oid,
            ],
            mutates=False,
        )
        rows = {}
        if res.rc == 0:
            for line in res.stdout.splitlines():
                parts = line.split()
                if len(parts) != 2:
                    continue
                oid = parts[0]
                if oid.startswith(base + "." + col_oid):
                    idx = oid[len(base + "." + col_oid) + 1:]
                    rows[idx] = parts[1].strip("\"")
        return rows

    status_rows = fetch_col("1")
    descr_rows = fetch_col("3")
    warn_rows = fetch_col("4")
    crit_rows = fetch_col("5")
    temp_rows = fetch_col("6")
    crit_react_rows = fetch_col("7")

    # Find the index of the row matching the requested item (description)
    target_idx = None
    for idx, descr in descr_rows.items():
        if descr == item:
            target_idx = idx
            break

    if target_idx == None:
        return {
            "changed": False,
            "msg": "Device " + item + " not found in SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = saveint(status_rows.get(target_idx, "0"))
    level_warn = saveint(warn_rows.get(target_idx, "0"))
    level_crit = saveint(crit_rows.get(target_idx, "0"))
    temp = saveint(temp_rows.get(target_idx, "0"))
    crit_react = crit_react_rows.get(target_idx, "0")

    status_map = {
        1: "unknown",
        2: "sensor-disabled",
        3: "ok",
        4: "sensor-failed",
        5: "warning-temp",
        6: "critical-temp",
        7: "not-available",
    }

    if crit_react != "2":
        return {
            "changed": False,
            "msg": "Temperature not present or poweroff",
            "data": {"state": "CRIT", "metrics": {"temp": float(temp)}, "details": ""},
        }
    if status != 3:
        return {
            "changed": False,
            "msg": "Status is " + status_map.get(status, "unknown"),
            "data": {"state": "CRIT", "metrics": {"temp": float(temp)}, "details": ""},
        }

    warn = params.get("warn", 60)
    crit = params.get("crit", 80)
    state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
    msg = "Temp: %s C, Status: %s" % (str(temp), status_map.get(status, "unknown"))
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {"temp": float(temp)}, "details": ""},
    }


def saveint(i):
    if i == None:
        return 0
    val = str(i).strip()
    sign = 1
    start = 0
    if val.startswith("-"):
        sign = -1
        start = 1
    body = val[start:]
    if body == "" or not body.isdigit():
        return 0
    return sign * int(body)