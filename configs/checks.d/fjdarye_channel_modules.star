def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: determine the device OID via sysObjectID
    sys_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_res.rc == 127:
        if params.get("_discover"):
            return {"changed": False, "msg": "snmp not installed", "data": {"discovery": []}}
        return {"changed": False, "msg": "snmp not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not sys_res.stdout or sys_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no fjdarye device detected",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no fjdarye device detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    device_oid = sys_res.stdout.strip()
    base_oid = device_oid + ".2.1.2.1"

    # Status mapping
    status_map = {
        "1": "OK",
        "2": "CRIT",
        "3": "WARN",
        "4": "CRIT",
        "5": "CRIT",
        "6": "CRIT",
    }
    status_summary = {
        "1": "Normal",
        "2": "Alarm",
        "3": "Warning",
        "4": "Invalid",
        "5": "Maintenance",
        "6": "Undefined",
    }

    if params.get("_discover"):
        # Walk columns 1 (index) and 3 (status) via -Oqn for clean table output
        walk_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-OQ", host, base_oid],
            mutates=False,
        )
        if walk_res.rc != 0 or not walk_res.stdout:
            return {"changed": False, "msg": "no fjdarye channel modules found",
                    "data": {"discovery": []}}

        items = []
        for line in walk_res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            oid_val = parts[0]
            value = parts[1]
            # The OID suffix tells us which column and the index
            suffix = oid_val[len(base_oid):]
            # suffix format: .<col>.<index>
            dot_idx = suffix.find(".", 1)
            if dot_idx < 0:
                continue
            col = suffix[1:dot_idx]
            index = suffix[1 + dot_idx + 1:]
            if col == "1":
                # This is the index column; we need the status from col 3
                items.append(index)
        
        # Deduplicate indices and fetch status for each
        seen = {}
        for idx in items:
            if idx in seen:
                continue
            seen[idx] = idx
            status_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host,
                 base_oid + ".3." + idx],
                mutates=False,
            )
            status_val = status_res.stdout.strip() if status_res.rc == 0 else ""
            if status_val == "4":
                continue  # Invalid items are not inventoried
            items.append(idx)

        discovery = []
        for idx in sorted(seen.keys()):
            discovery.append({
                "item": idx,
                "params": {},
                "metrics": ["status"],
            })
        return {"changed": False, "msg": "discovered %d fjdarye channel modules" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode - check a single item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch status for the specific item
    status_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         base_oid + ".3." + item],
        mutates=False,
    )
    if status_res.rc != 0 or not status_res.stdout:
        return {"changed": False, "msg": "could not fetch status for module " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_val = status_res.stdout.strip()
    state = status_map.get(status_val, "UNKNOWN")
    summary = status_summary.get(status_val, "Unknown")
    msg = "Controller Module %s: %s" % (item, summary)
    metrics = {}
    if state != "UNKNOWN":
        # Encode state numerically for metric: 1=OK, 2=WARN, 3=CRIT
        state_num = {"OK": 1, "WARN": 2, "CRIT": 3}.get(state, 0)
        metrics = {"status": state_num}
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": "Status: " + summary}}