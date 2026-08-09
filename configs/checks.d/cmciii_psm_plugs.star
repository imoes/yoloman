def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the Rittal LCP device itself.
    sys_descr = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Ov", "-OQ",
        host, ".1.3.6.1.2.1.1.1.0"
    ], mutates=False)
    if sys_descr.rc != 0 or not sys_descr.stdout:
        return {"discovery": []}
    if not sys_descr.stdout.startswith("Rittal LCP"):
        return {"discovery": []}

    # Column OIDs from Rittal cmciii convention.
    col_index = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.5"

    # Walk the index column to enumerate plug sensors.
    idx_walk = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", "-OQ",
        host, col_index
    ], mutates=False)
    if idx_walk.rc != 0:
        return {"discovery": []}

    out = []
    for line in idx_walk.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        oid = parts[0]
        if not oid.startswith(col_index + "."):
            continue
        index = oid[len(col_index) + 1:]
        out.append({
            "item": index,
            "params": {"_item_key": index},
            "metrics": []
        })

    return {"discovery": out}


def _check(ctx, params):
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the Rittal LCP device.
    sys_descr = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Ov", "-OQ",
        host, ".1.3.6.1.2.1.1.1.0"
    ], mutates=False)
    if sys_descr.rc != 0 or not sys_descr.stdout:
        return {"state": "UNKNOWN", "msg": "no Rittal LCP device found",
                "metrics": {}, "details": ""}
    if not sys_descr.stdout.startswith("Rittal LCP"):
        return {"state": "UNKNOWN", "msg": "no Rittal LCP device found",
                "metrics": {}, "details": ""}

    col_status = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.7"
    col_desc = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
    col_loc = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.4"
    col_index = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.5"

    # Resolve _item_key if present (use_sensor_description compatibility).
    item_key = params.get("_item_key")
    if not item_key:
        # Resolve item name to index by walking the index column.
        idx_walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn", "-OQ",
            host, col_index
        ], mutates=False)
        if idx_walk.rc == 0:
            for line in idx_walk.stdout.splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                oid = parts[0]
                if not oid.startswith(col_index + "."):
                    continue
                index = oid[len(col_index) + 1:]
                # Check description match.
                desc_res = ctx.run([
                    "snmpget", "-v2c", "-c", community, "-Oqv", "-OQ",
                    host, col_desc + "." + index
                ], mutates=False)
                if desc_res.rc == 0 and desc_res.stdout == item:
                    item_key = index
                    break
                # Check location match.
                loc_res = ctx.run([
                    "snmpget", "-v2c", "-c", community, "-Oqv", "-OQ",
                    host, col_loc + "." + index
                ], mutates=False)
                if loc_res.rc == 0 and loc_res.stdout == item:
                    item_key = index
                    break

    if not item_key:
        return {"state": "UNKNOWN", "msg": "no such psm plug: " + item,
                "metrics": {}, "details": ""}

    # Read status for the resolved index.
    status_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", "-OQ",
        host, col_status + "." + item_key
    ], mutates=False)
    if status_res.rc != 0:
        return {"state": "UNKNOWN", "msg": "no such psm plug: " + item,
                "metrics": {}, "details": ""}

    state_readable = status_res.stdout
    if not state_readable:
        return {"state": "UNKNOWN", "msg": "no such psm plug: " + item,
                "metrics": {}, "details": ""}

    state = "OK" if state_readable == "OK" else "CRIT"
    return {"state": state, "msg": "Status: " + state_readable,
            "metrics": {}, "details": ""}


def main(ctx, params):
    if params.get("_discover"):
        discovery = _discover(ctx, params)
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery["discovery"]),
                "data": discovery}
    result = _check(ctx, params)
    return {"changed": False,
            "msg": result["msg"],
            "data": {
                "state": result["state"],
                "metrics": result["metrics"],
                "details": result["details"]
            }}