def main(ctx, params):
    # === Constants ===
    BASE_OID_SRC1 = ".1.3.6.1.4.1.705.2.3.2.1"
    BASE_OID_SRC2 = ".1.3.6.1.4.1.705.2.4.2.1"
    OIDS = ["2", "3", "4"]  # voltage, current, power

    # === Discovery mode ===
    if params.get("_discover"):
        items = []
        for src in (1, 2):
            base = BASE_OID_SRC1 if src == 1 else BASE_OID_SRC2
            for phs in (1, 2, 3):
                item = "Source %d Phase %d" % (src, phs)
                items.append({
                    "item": item,
                    "params": {},
                    "metrics": ["voltage", "current", "power"]
                })
        return {
            "changed": False,
            "msg": "discovered %d inputs" % len(items),
            "data": {"discovery": items}
        }

    # === Check mode ===
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item is required",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine source and phase from item
    parts = item.split()
    if len(parts) != 3 or parts[0] != "Source" or parts[2] != "Phase":
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    try_src = parts[1]
    try_ph = parts[3]
    if not try_src.isdigit() or not try_ph.isdigit():
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    src = int(try_src)
    phs = int(try_ph)

    base_oid = BASE_OID_SRC1 if src == 1 else BASE_OID_SRC2

    # Build complete OIDs for this source/phase
    oids_to_get = []
    for oid_base in OIDS:
        full_oid = base_oid + "." + oid_base + "." + str(phs)
        oids_to_get.append(full_oid)

    # Use snmpget for each OID individually
    values = []
    for full_oid in oids_to_get:
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), 
                       "-On", params.get("host", "localhost"), full_oid], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpget failed for " + full_oid,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        line = res.stdout.strip()
        eq_pos = line.find("=")
        if eq_pos == -1:
            return {
                "changed": False,
                "msg": "unexpected snmpget output for " + full_oid + ": " + line,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        value_str = line[eq_pos+1:].strip()
        if value_str.find(":") != -1:
            value_str = value_str.split(":", 1)[1].strip()
        if not value_str.isdigit():
            return {
                "changed": False,
                "msg": "cannot parse value for " + full_oid + ": " + value_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        values.append(int(value_str))

    if len(values) != 3:
        return {
            "changed": False,
            "msg": "expected 3 values for " + item + ", got " + str(len(values)),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    voltage = float(values[0]) / 10.0
    current = float(values[1]) / 10.0
    power = float(values[2])

    # Get thresholds from params (check_default_parameters = {})
    warn_v = params.get("voltage_levels_lower", 200.0)
    crit_v = params.get("voltage_levels_lower_critical", 180.0)
    warn_c = params.get("current_levels_lower", 0.0)
    crit_c = params.get("current_levels_lower_critical", 0.0)
    warn_p = params.get("power_levels_lower", 0.0)
    crit_p = params.get("power_levels_lower_critical", 0.0)

    state = "OK"
    if voltage <= crit_v:
        state = "CRIT"
    elif voltage <= warn_v and state != "CRIT":
        state = "WARN"
    if current <= crit_c:
        state = "CRIT"
    elif current <= warn_c and state != "CRIT":
        state = "WARN"
    if power <= crit_p:
        state = "CRIT"
    elif power <= warn_p and state != "CRIT":
        state = "WARN"

    msg = "Voltage: %f V, Current: %f A, Power: %f W" % (voltage, current, power)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "voltage": voltage,
                "current": current,
                "power": power
            },
            "details": ""
        }
    }
