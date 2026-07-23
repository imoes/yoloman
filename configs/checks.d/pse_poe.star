def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.2.1.105.1.3.1.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        # Parse OID ends and their values from snmpwalk output:
        # e.g., ".1.3.6.1.2.1.105.1.3.1.1.1 = INTEGER: 30.0" etc. (we need column 2,3,4 for each OID end)
        # We must collect columns 2,3,4 together per OID end.
        # Approach: collect all rows, group by OID end.
        rows = res.stdout.strip().splitlines()
        data = {}
        for row in rows:
            if not row or "=" not in row:
                continue
            parts = row.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value_str = parts[1].strip()
            # Extract OID end: split by '.' and take the last number
            segments = oid_full.split(".")
            if len(segments) < 10:
                continue
            oid_end = segments[-1]
            # Determine column index relative to base_oid: base is .1.3.6.1.2.1.105.1.3.1.1 (10 segments)
            # So oid_full has 10+k segments; column index = k
            # base_oid segments: 10; we want column 2,3,4 meaning k=1,2,3 (since base ends at 1)
            # Actually base OID is ".1.3.6.1.2.1.105.1.3.1.1" (length 10), so:
            # .1.3.6.1.2.1.105.1.3.1.1.1 (column 1) -> k=1 -> column index 1
            # .1.3.6.1.2.1.105.1.3.1.1.2 (column 2) -> k=2 -> column index 2
            # .1.3.6.1.2.1.105.1.3.1.1.3 (column 3) -> k=3 -> column index 3
            # .1.3.6.1.2.1.105.1.3.1.1.4 (column 4) -> k=4 -> column index 4
            # So column index = len(segments) - 9
            col_idx = len(segments) - 9
            # Only columns 2,3,4 (pethMainPsePower, pethMainPseOperStatus, pethMainPseConsumptionPower)
            if col_idx < 2 or col_idx > 4:
                continue
            # Store value keyed by (oid_end, col_idx)
            key = (oid_end, col_idx)
            data[key] = value_str

        # Now reassemble per oid_end: collect (poe_max, pse_op_status, poe_used)
        # For each oid_end, look up keys (oid_end,2), (oid_end,3), (oid_end,4)
        items = []
        seen_oids = set()
        for (oid_end, col_idx), value in data.items():
            if oid_end not in seen_oids:
                seen_oids.add(oid_end)
        for oid_end in seen_oids:
            poe_max_str = data.get((oid_end, 2), "")
            pse_op_str = data.get((oid_end, 3), "")
            poe_used_str = data.get((oid_end, 4), "")
            # Skip if any missing
            if not poe_max_str or not pse_op_str or not poe_used_str:
                continue
            # Parse values
            if not poe_max_str.isdigit() or not pse_op_str.isdigit() or not poe_used_str.isdigit():
                continue
            poe_max = float(poe_max_str)
            pse_op = int(pse_op_str)
            poe_used = float(poe_used_str)
            items.append({
                "item": oid_end,
                "params": {"levels": ("fixed", (90.0, 95.0))},
                "metrics": ["power_usage_percentage"]
            })
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.2.1.105.1.3.1.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    rows = res.stdout.strip().splitlines()
    data = {}
    for row in rows:
        if not row or "=" not in row:
            continue
        parts = row.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_str = parts[1].strip()
        segments = oid_full.split(".")
        if len(segments) < 10:
            continue
        oid_end = segments[-1]
        if oid_end != item:
            continue
        col_idx = len(segments) - 9
        if col_idx < 2 or col_idx > 4:
            continue
        data[col_idx] = value_str

    if (2,3,4) not in [(2,), (3,), (4,)] and not (2 in data and 3 in data and 4 in data):
        return {"changed": False, "msg": "no data for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    poe_max_str = data.get(2, "")
    pse_op_str = data.get(3, "")
    poe_used_str = data.get(4, "")

    # Sanity check
    if not poe_max_str.isdigit() or not pse_op_str.isdigit() or not poe_used_str.isdigit():
        return {"changed": False, "msg": "Device returned faulty data: nominal power: %s, power consumption: %s, operational status: %s" % (poe_max_str, poe_used_str, pse_op_str),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    poe_max = float(poe_max_str)
    pse_op = int(pse_op_str)
    poe_used = float(poe_used_str)

    # State checks
    if pse_op < 1 or pse_op > 3:
        return {"changed": False, "msg": "Device returned faulty data: nominal power: %s, power consumption: %s, operational status: %s" % (poe_max_str, poe_used_str, pse_op_str),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if pse_op == 1:  # ON
        if poe_max > 0:
            usage_pct = ((poe_used / poe_max) * 100.0)
        else:
            usage_pct = 0.0
        # Levels: default ("fixed", (90.0, 95.0))
        levels = params.get("levels", ("fixed", (90.0, 95.0)))
        if type(levels) == "list" and len(levels) == 2:
            levels = ("fixed", levels)
        if levels[0] != "fixed" or len(levels[1]) != 2:
            return {"changed": False, "msg": "invalid levels config",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        warn, crit = float(levels[1][0]), float(levels[1][1])
        if usage_pct >= crit:
            state = "CRIT"
        elif usage_pct >= warn:
            state = "WARN"
        else:
            state = "OK"
        return {"changed": False,
                "msg": "POE usage (%fW/%fW): %f%%" % (poe_used, poe_max, usage_pct),
                "data": {"state": state, "metrics": {"power_usage_percentage": usage_pct}, "details": ""}}

    if pse_op == 2:  # OFF
        return {"changed": False, "msg": "Operational status of the PSE is OFF",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    if pse_op == 3:  # FAULTY
        return {"changed": False, "msg": "Operational status of the PSE is FAULTY",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # Should not happen, but fallback
    return {"changed": False, "msg": "unknown operational status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}