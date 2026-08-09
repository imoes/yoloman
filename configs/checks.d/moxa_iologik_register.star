def main(ctx, params):
    base = ".1.3.6.1.4.1.8691.10.2242.10.4.1.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Check if the device is a Moxa E2242-T via sysObjectID
        sys_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_res.rc != 0 or sys_res.stdout == "":
            return {"changed": False, "msg": "not a Moxa device", "data": {"discovery": []}}
        if not sys_res.stdout.startswith(".1.3.6.1.4.1.8691."):
            return {"changed": False, "msg": "not a Moxa device", "data": {"discovery": []}}

        # Check model name
        model_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.8691.10.2242.2.0"], mutates=False)
        if model_res.rc != 0 or not model_res.stdout.startswith("E2242-T"):
            return {"changed": False, "msg": "not a Moxa E2242-T", "data": {"discovery": []}}

        # Walk the three columns of the DIO entry table
        col1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1"], mutates=False)
        col2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2"], mutates=False)
        col3 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".3"], mutates=False)

        # Build a dict: index -> [col1_val, col2_val, col3_val]
        rows = {}
        for res, col_idx in [(col1, 0), (col2, 1), (col3, 2)]:
            if res.rc == 0 and res.stdout:
                for line in res.stdout.splitlines():
                    parts = line.split(" ", 1)
                    if len(parts) != 2:
                        continue
                    oid = parts[0]
                    value = parts[1]
                    idx = oid[len(base + ".1"):] if col_idx == 0 else None
                    if col_idx == 0:
                        idx = oid[len(base) + 2:]
                    if col_idx == 1:
                        idx = oid[len(base) + 2:]
                    if col_idx == 2:
                        idx = oid[len(base) + 2:]
                    if idx not in rows:
                        rows[idx] = [None, None, None]
                    rows[idx][col_idx] = value

        out = []
        for idx in sorted(rows.keys()):
            row = rows[idx]
            if len(row) >= 3 and row[2] and row[2] != "No Such Instance":
                out.append({"item": row[0], "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d registers" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    # Re-fetch all columns to find the matching item
    col1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1"], mutates=False)
    col2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2"], mutates=False)
    col3 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".3"], mutates=False)

    rows = {}
    for res, col_idx in [(col1, 0), (col2, 1), (col3, 2)]:
        if res.rc == 0 and res.stdout:
            for line in res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid = parts[0]
                value = parts[1]
                idx = oid[len(base) + 2:]
                if idx not in rows:
                    rows[idx] = [None, None, None]
                rows[idx][col_idx] = value

    # Find the row where column 1 matches the item
    found = None
    for idx in rows:
        if rows[idx][0] == item:
            found = rows[idx]
            break

    if found == None:
        return {"changed": False, "msg": "Register not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val = found[2]
    if val == None or val == "" or val.startswith("No Such"):
        return {"changed": False, "msg": "Register not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    v = 0
    if val.isdigit():
        v = int(val)

    if v in [0, 1]:
        state = "OK" if v == 0 else "WARN"
        return {"changed": False, "msg": found[1],
                "data": {"state": state, "metrics": {}, "details": str(found[2])}}
    else:
        return {"changed": False, "msg": "Invalid value " + str(found[2]) + " for register",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}