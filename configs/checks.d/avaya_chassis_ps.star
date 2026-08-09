def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Probe: is this an Avaya chassis?
        detect = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Ov", host,
             ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if detect.rc == 127:
            return {"changed": False, "msg": "snmpget not installed",
                    "data": {"discovery": []}}
        if detect.rc != 0:
            return {"changed": False, "msg": "snmpget failed: " + detect.stderr,
                    "data": {"discovery": []}}
        sys_oid = detect.stdout.strip()
        # strip type tag: "STRING: ..." / "OID: ..." -> value
        if ": " in sys_oid:
            sys_oid = sys_oid.split(": ", 1)[1]
        sys_oid = sys_oid.strip().strip('"')
        if not sys_oid.startswith(".1.3.6.1.4.1.2272"):
            return {"changed": False, "msg": "not an Avaya chassis",
                    "data": {"discovery": []}}

        # Fetch power supply table: base .1.3.6.1.4.1.2272.1.4.8.1.1, cols 1,2
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.2272.1.4.8.1.1.1"],
            mutates=False,
        )
        if walk.rc != 0 and walk.stdout == "":
            return {"changed": False, "msg": "no power supply data",
                    "data": {"discovery": []}}

        col1 = {}  # index -> name
        col2 = {}  # index -> status code
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid, value = parts[0], parts[1]
            idx = oid[len(".1.3.6.1.4.1.2272.1.4.8.1.1.1") + 1:]
            col1[idx] = value

        # fetch column 2 separately
        walk2 = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.2272.1.4.8.1.1.2"],
            mutates=False,
        )
        if walk2.rc == 0 and walk2.stdout != "":
            for line in walk2.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid, value = parts[0], parts[1]
                idx = oid[len(".1.3.6.1.4.1.2272.1.4.8.1.1.2") + 1:]
                col2[idx] = value

        discovery = []
        seen = set()
        for idx in sorted(col1.keys()):
            name = col1[idx]
            status_val = col2.get(idx, "2")  # "2" = not installed
            # Discover only installed power supplies (status != "2")
            if status_val == "2":
                continue
            if name in seen:
                continue
            seen.add(name)
            discovery.append({
                "item": name,
                "params": {},
                "metrics": [],
            })
        return {"changed": False,
                "msg": "discovered %d power supplies" % len(discovery),
                "data": {"discovery": discovery}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Re-fetch the table; correlate rows by index, match by name (col 1)
    walk1 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         ".1.3.6.1.4.1.2272.1.4.8.1.1.1"],
        mutates=False,
    )
    col1 = {}
    idx_by_name = {}
    if walk1.rc == 0 and walk1.stdout != "":
        for line in walk1.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid, value = parts[0], parts[1]
            idx = oid[len(".1.3.6.1.4.1.2272.1.4.8.1.1.1") + 1:]
            col1[idx] = value
            idx_by_name[value] = idx

    if item not in idx_by_name:
        return {"changed": False,
                "msg": "no such power supply: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    idx = idx_by_name[item]
    walk2 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         ".1.3.6.1.4.1.2272.1.4.8.1.1.2"],
        mutates=False,
    )
    col2 = {}
    if walk2.rc == 0 and walk2.stdout != "":
        for line in walk2.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid, value = parts[0], parts[1]
            row_idx = oid[len(".1.3.6.1.4.1.2272.1.4.8.1.1.2") + 1:]
            col2[row_idx] = value

    status_code_str = col2.get(idx, "1")
    # parse int safely
    code = int(status_code_str) if status_code_str.isdigit() else 1

    codes = {
        1: ("UNKNOWN", "unknown", "Status cannot be determined"),
        2: ("WARN", "empty", "Power supply not installed"),
        3: ("OK", "up", "Present and supplying power"),
        4: ("CRIT", "down", "Failure indicated"),
    }
    state, name, desc = codes.get(code, (codes.get(1)))
    if state == "UNKNOWN":
        state = "UNKNOWN"
    msg = desc + " (" + name + ")"
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}