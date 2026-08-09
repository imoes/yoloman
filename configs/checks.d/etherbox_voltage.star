def main(ctx, params):
    # Default values from Checkmk check
    levels = params.get("levels", ("no_levels", None))

    # === DISCOVERY MODE ===
    if params.get("_discover"):
        # Get sensor data via snmpwalk
        res_sensors = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                               "-On", params.get("host", "localhost"),
                               ".1.3.6.1.4.1.14848.2.1.2.1"], mutates=False)
        if res_sensors.rc != 0 or not res_sensors.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        # Parse sensor data
        out = []
        for line in res_sensors.stdout.splitlines():
            if not line.strip():
                continue
            # Parse snmpwalk output: OID = TYPE: VALUE
            eq_idx = line.find(" = ")
            if eq_idx < 0:
                continue
            oid_full = line[:eq_idx].strip()
            value_str = line[eq_idx + 3:].strip()

            # Extract value (last part after colon)
            val_parts = value_str.split(":")
            if len(val_parts) < 2:
                continue
            value = val_parts[-1].strip()
            if not value.isdigit():
                continue
            value = int(value)

            # Extract index and type from OID
            # OID format: .1.3.6.1.4.1.14848.2.1.2.1.<index>.<name>.<type>.<unknown>.<value>
            oid_parts = oid_full.split(".")
            if len(oid_parts) < 11:
                continue
            index = oid_parts[-5]
            sensor_type = oid_parts[-3]

            # Filter for voltage sensor (type "5")
            if sensor_type == "5":
                item = index + "." + sensor_type
                out.append({"item": item, "params": {"levels": levels},
                           "metrics": ["voltage"]})

        return {"changed": False, "msg": "discovered %d voltage sensors" % len(out),
                "data": {"discovery": out}}

    # === CHECK MODE ===
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = item.split(".")
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item_index, item_type = parts[0], parts[1]
    if item_type != "5":
        return {"changed": False, "msg": "item is not a voltage sensor",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get sensor value via snmpget
    oid_path = ".1.3.6.1.4.1.14848.2.1.2.1." + item_index + ".1.5.1"
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), oid_path], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "sensor not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse value
    eq_idx = res.stdout.find(" = ")
    if eq_idx < 0:
        return {"changed": False, "msg": "could not parse sensor value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_str = res.stdout[eq_idx + 3:].strip()
    val_parts = value_str.split(":")
    if len(val_parts) < 2:
        return {"changed": False, "msg": "could not parse sensor value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_str = val_parts[-1].strip()
    if not value_str.isdigit():
        return {"changed": False, "msg": "could not parse sensor value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = int(value_str)

    # Get sensor name
    name_oid = ".1.3.6.1.4.1.14848.2.1.2.1." + item_index + ".2.5.1"
    res_name = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), name_oid], mutates=False)
    sensor_name = "Sensor " + item_index
    if res_name.rc == 0 and res_name.stdout.strip():
        name_eq_idx = res_name.stdout.find(" = ")
        if name_eq_idx >= 0:
            name_str = res_name.stdout[name_eq_idx + 3:].strip()
            name_colon_idx = name_str.find(":")
            if name_colon_idx >= 0:
                sensor_name = name_str[name_colon_idx + 1:].strip()

    # Process voltage value
    voltage_v = float(value) / 10.0  # value is in 0.1V units
    state = "OK"
    msg_parts = ["Voltage %f V" % voltage_v]

    if levels and levels[0] != "no_levels":
        warn_val = None
        crit_val = None
        if levels[1] != None and len(levels[1]) == 2:
            warn_val = levels[1][0]
            crit_val = levels[1][1]

        # Upper levels (voltage >= threshold triggers alert)
        if crit_val != None and voltage_v >= crit_val:
            state = "CRIT"
            msg_parts.append("CRIT (warn at %f V, crit at %f V)" % (warn_val if warn_val != None else 0.0, crit_val))
        elif warn_val != None and voltage_v >= warn_val:
            state = "WARN"
            msg_parts.append("WARN (warn at %f V, crit at %f V)" % (warn_val, crit_val if crit_val != None else 0.0))

    return {"changed": False, "msg": sensor_name + " - " + ", ".join(msg_parts),
            "data": {"state": state, "metrics": {"voltage": voltage_v}, "details": ""}}
