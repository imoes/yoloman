def main(ctx, params):
    # Configuration constants
    SNMP_COMMUNITY = params.get("community", "public")
    SNMP_HOST = params.get("host", "localhost")
    OID_BASE = ".1.3.6.1.4.1.14848.2.1"
    OID_UNIT = OID_BASE + ".1.3"   # temperature unit
    OID_SENSOR_BASE = OID_BASE + ".2.1.1"
    OID_SENSOR_INDEX = OID_SENSOR_BASE + ".1"
    OID_SENSOR_NAME = OID_SENSOR_BASE + ".2"
    OID_SENSOR_TYPE = OID_SENSOR_BASE + ".3"
    OID_SENSOR_VALUE = OID_SENSOR_BASE + ".5"

    if params.get("_discover"):
        # Discovery mode: walk sensor data and enumerate temperature sensors
        # 1. Fetch unit of measurement (c=0, f=1, k=2)
        res_unit = ctx.run(["snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, OID_UNIT], mutates=False)
        unit = "c"  # default to Celsius if parse fails
        for line in res_unit.stdout.splitlines():
            if line.strip():
                val = line.strip().split()[-1]
                if val.isdigit():
                    unit_map = {"0": "c", "1": "f", "2": "k"}
                    unit = unit_map.get(val, "c")
                    break

        # 2. Fetch all sensor records
        res_sensors = ctx.run([
            "snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST,
            OID_SENSOR_INDEX
        ], mutates=False)

        sensors = {}  # index -> {"name": str, "type": str, "value": int}
        for line in res_sensors.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            value_str = parts[-1]
            if not value_str.isdigit():
                continue
            # Parse OID to get index (last component)
            oid_full = parts[0]
            index = oid_full.split(".")[-1]
            sensors[index] = {"value": int(value_str) * 10}  # value in 1/10 units

        # Fetch sensor name, type, and full value via snmpget per index (to avoid mismatched rows)
        # Build lookup for name/type by index
        name_types = {}
        for index in sensors:
            name_oid = OID_SENSOR_NAME + "." + index
            type_oid = OID_SENSOR_TYPE + "." + index
            res_name = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, name_oid], mutates=False)
            res_type = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, type_oid], mutates=False)

            name_val = ""
            type_val = ""
            for line in res_name.stdout.splitlines():
                if "=" in line:
                    name_val = line.split("=", 1)[-1].strip()
                    break
            for line in res_type.stdout.splitlines():
                if "=" in line:
                    type_val = line.split("=", 1)[-1].strip()
                    break

            name_types[index] = {"name": name_val, "type": type_val}

        # Merge sensor data and produce discovery entries for temperature (type "1")
        discovery_items = []
        for idx in name_types:
            if idx not in sensors:
                continue
            sensor_type = name_types[idx]["type"]
            if sensor_type != "1":
                continue
            value_10 = sensors[idx]["value"]
            # Skip zero-value temperature sensors (no sensor connected)
            if value_10 == 0:
                continue
            item_name = idx + ".1"
            discovery_items.append({
                "item": item_name,
                "params": {},
                "metrics": ["temp"]
            })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    parts = item.split(".")
    if len(parts) != 2 or parts[1] != "1":
        return {
            "changed": False,
            "msg": "invalid item format (expected 'index.1')",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    idx = parts[0]
    # Fetch sensor data
    name_oid = OID_SENSOR_NAME + "." + idx
    type_oid = OID_SENSOR_TYPE + "." + idx
    value_oid = OID_SENSOR_VALUE + "." + idx
    unit_oid = OID_BASE + ".1.3"

    res_name = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, name_oid], mutates=False)
    res_type = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, type_oid], mutates=False)
    res_value = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, value_oid], mutates=False)
    res_unit = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, unit_oid], mutates=False)

    name = ""
    sensor_type = ""
    value_raw = ""
    unit_val = ""

    for line in res_name.stdout.splitlines():
        if "=" in line:
            name = line.split("=", 1)[-1].strip()
            break
    for line in res_type.stdout.splitlines():
        if "=" in line:
            sensor_type = line.split("=", 1)[-1].strip()
            break
    for line in res_value.stdout.splitlines():
        if "=" in line:
            value_raw = line.split("=", 1)[-1].strip()
            break
    for line in res_unit.stdout.splitlines():
        if "=" in line:
            unit_val = line.split("=", 1)[-1].strip()
            break

    # Validate
    if name == "":
        return {
            "changed": False,
            "msg": "sensor not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if sensor_type != "1":
        return {
            "changed": False,
            "msg": "sensor type mismatch (expected type 1/temperature)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if not value_raw.isdigit():
        return {
            "changed": False,
            "msg": "unable to read temperature value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if unit_val not in ["0", "1", "2"]:
        return {
            "changed": False,
            "msg": "invalid temperature unit",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Convert value: raw is in 1/10 units
    temp_value = float(value_raw) / 10.0
    unit_map = {"0": "c", "1": "f", "2": "k"}
    unit = unit_map[unit_val]

    # Threshold logic: default Checkmk temperature levels
    # Checkmk uses params dict with keys 'levels' (tuple (warn, crit) or 'no_levels')
    levels = params.get("levels", ("no_levels", None))
    if levels == None:
        levels = ("no_levels", None)

    state = "OK"
    warn_val = None
    crit_val = None
    if levels[0] == "absolute":
        warn_val = levels[1][0]
        crit_val = levels[1][1]
    elif levels[0] == "relative":
        # Not supported by this simplified translation; fall back to absolute logic
        pass
    elif levels[0] == "no_levels":
        # No thresholds
        pass

    # Apply thresholds if defined
    if warn_val != None and crit_val != None:
        if temp_value >= crit_val:
            state = "CRIT"
        elif temp_value >= warn_val:
            state = "WARN"
    elif warn_val != None:
        if temp_value >= warn_val:
            state = "WARN"

    # Build summary
    unit_label = {"c": "C", "f": "F", "k": "K"}.get(unit, unit.upper())
    msg = "[{}] {} {}".format(name, temp_value, unit_label)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": temp_value},
            "details": ""
        },
    }
