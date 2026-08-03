def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    use_sensor_description = params.get("use_sensor_description", False)

    def snmp_walk(oid):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community,
            "-Oqn", host, oid
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return []
        rows = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            full_oid = parts[0]
            value = parts[1]
            rows.append((full_oid, value))
        return rows

    def snmp_get(oid):
        res = ctx.run([
            "snmpget", "-v2c", "-c", community,
            "-Oqv", host, oid
        ], mutates=False)
        if res.rc != 0:
            return None
        return res.stdout.strip()

    # Probe for the real thing — Rittal LCP device
    sys_descr = snmp_get(".1.3.6.1.2.1.1.1.0")
    if sys_descr == None or not sys_descr.startswith("Rittal LCP"):
        if not params.get("_discover"):
            return {
                "changed": False,
                "msg": "not a Rittal LCP device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no Rittal LCP device found"},
            }
        return {"changed": False, "msg": "no Rittal LCP detected", "data": {"discovery": [], "host_labels": {}}}

    # Determine the leakage table column OIDs
    # Based on Rittal CMCIII MIB: leakage table at .1.3.6.1.4.1.2606.7.4.2.2.1.3.5
    # Columns: DescName(.1), Status(.2), Delay(.3)
    leakage_table_base = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.5"
    descname_oid = leakage_table_base + ".1"
    status_oid = leakage_table_base + ".2"
    delay_oid = leakage_table_base + ".3"

    # Walk the DescName column to discover leakage sensor items
    desc_rows = snmp_walk(descname_oid)
    # Also walk Status to build index->status mapping
    status_rows = snmp_walk(status_oid)
    delay_rows = snmp_walk(delay_oid)

    # Build index -> {field: value} mapping
    def build_map(rows):
        m = {}
        for full_oid, value in rows:
            index = full_oid[len(leakage_table_base) + 1:]
            m[index] = value
        return m

    desc_map = build_map(desc_rows)
    status_map = build_map(status_rows)
    delay_map = build_map(delay_rows)

    # Collect all indices
    all_indices = list(desc_map.keys())
    # Also include indices from status/delay that aren't in desc
    for idx in status_map:
        if idx not in desc_map:
            all_indices.append(idx)
    for idx in delay_map:
        if idx not in desc_map and idx not in status_map:
            all_indices.append(idx)

    # Discovery mode
    if params.get("_discover"):
        discovery = []
        for idx in all_indices:
            desc = desc_map.get(idx, "")
            if use_sensor_description:
                location = desc_map.get("Location", "")  # not available
                item = "%s" % idx
            else:
                item = idx
            discovery.append({
                "item": item,
                "params": {"_item_key": idx},
                "metrics": ["status", "delay"],
            })
        return {
            "changed": False,
            "msg": "discovered %d leakage sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    item_key = params.get("_item_key", item)

    # Find the sensor entry
    status = status_map.get(item_key)
    delay = delay_map.get(item_key)

    if status == None and delay == None:
        return {
            "changed": False,
            "msg": "no leakage sensor found for item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "sensor not found"},
        }

    status_text = status if status != None else "notAvail"
    delay_text = delay if delay != None else "unknown"

    state = "CRIT" if status_text != "OK" else "OK"

    return {
        "changed": False,
        "msg": "Status: %s, Delay: %s" % (status_text, delay_text),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }