def main(ctx, params):
    if params.get("_discover"):
        base = ".1.3.6.1.4.1.2.3.51.2.2.4.1.1"
        cols = ["1", "2", "3", "4"]
        walk_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), base],
            mutates=False,
        )
        if walk_res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"discovery": [], "host_labels": {}}}

        rows = {}
        for line in walk_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, value = parts
            suffix = oid[len(base) + 1:]
            bits = suffix.split(".")
            if len(bits) != 2:
                continue
            col_idx = int(bits[0])
            index = bits[1]
            if col_idx < 1 or col_idx > 4:
                continue
            rows.setdefault(index, [""] * 4)[col_idx - 1] = value

        discovery = []
        for index, vals in rows.items():
            if len(vals) < 4:
                continue
            name = vals[0]
            present = vals[1]
            if present == "1":
                discovery.append({
                    "item": name,
                    "params": {},
                    "metrics": [],
                })

        return {"changed": False,
                "msg": "discovered %d power modules" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {"cmk/os_family": "linux"}}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.2.3.51.2.2.4.1.1"
    cols = ["1", "2", "3", "4"]
    oids = [base + "." + c for c in cols]
    get_res = ctx.run(
        ["snmpbulkget", "-v2c", "-c", params.get("community", "public"),
         "-C", "1", "-Oqv" if False else "-OQ", 
         params.get("host", "localhost")] + oids,
        mutates=False,
    )
    if get_res.rc == 127:
        return {"changed": False, "msg": "not installed: snmp",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "not installed"}}
    if get_res.rc != 0:
        return {"changed": False, "msg": "snmpbulkget failed: " + get_res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fields = get_res.stdout.split("\n")
    values = []
    i = 0
    while i < len(fields):
        line = fields[i].strip()
        if line == "":
            i += 1
            continue
        if line.startswith(base + "."):
            oid_part = line
            i += 1
            while i < len(fields) and not fields[i].strip().startswith(base + "."):
                i += 1
            val = oid_part.split(" ", 1)[1] if " " in oid_part else oid_part
            values.append(val)
        else:
            values.append(line)
            i += 1

    if len(values) < 4:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "missing columns"}}

    name = values[0]
    present = values[1]
    status = values[2]
    text = values[3]

    if name != item:
        return {"changed": False, "msg": "item mismatch",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if present != "1":
        return {"changed": False, "msg": "Not present",
                "data": {"state": "CRIT", "metrics": {}, "details": text}}

    state = "OK" if status == "1" else "CRIT"
    return {"changed": False, "msg": text,
            "data": {"state": state, "metrics": {}, "details": text}}