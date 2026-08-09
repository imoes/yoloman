def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Gather DOM sensors from SNMP
        community = params.get("community", "public")
        host = params.get("host", "localhost")

        # Fetch descriptions to map item names to sensor IDs
        res_desc = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.2.1.47.1.1.1.1.7"
        ], mutates=False)

        descriptions = {}
        for line in res_desc.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            if not oid.startswith(".1.3.6.1.2.1.47.1.1.1.1.7."):
                continue
            sensor_id = oid.rsplit(".", 1)[-1]
            val = parts[1].strip()
            if val.startswith("STRING: "):
                val = val[8:].strip('"')
            if sensor_id.isdigit():
                descriptions[sensor_id] = val

        # Fetch sensor types to identify DOM (type 14) sensors
        res_type = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.9.9.91.1.1.1.1.1"
        ], mutates=False)

        dom_sensor_ids = []
        for line in res_type.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            if not oid.startswith(".1.3.6.1.4.1.9.9.91.1.1.1.1.1."):
                continue
            sensor_id = oid.rsplit(".", 1)[-1]
            val = parts[1].strip()
            if val.startswith("INTEGER: ") and val.endswith(" 14"):
                dom_sensor_ids.append(sensor_id)

        # For each DOM sensor, check status and discover if normal/warning/critical/shutdown
        discovery_items = []
        for sid in dom_sensor_ids:
            # Get status
            res_status = ctx.run([
                "snmpget", "-v2c", "-c", community, "-On",
                host, ".1.3.6.1.4.1.9.9.91.1.1.1.1.5.%s" % sid
            ], mutates=False)

            status = "1"
            for line in res_status.stdout.splitlines():
                if "INTEGER: " in line:
                    status = line.split("INTEGER: ")[1].strip()
                    break

            # Only discover if status is 1,2,3,4 (normal, warning, critical, shutdown)
            if status not in ["1", "2", "3", "4"]:
                continue

            item = descriptions.get(sid, sid)
            if not item:
                item = sid

            discovery_items.append({
                "item": item,
                "params": {"admin_states": ["1"]},
                "metrics": ["input_signal_power_dbm", "output_signal_power_dbm"]
            })

        return {
            "changed": False,
            "msg": "discovered %d DOM sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }

    # Check mode
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Find sensor ID by description
    res_desc = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.2.1.47.1.1.1.1.7"
    ], mutates=False)

    sensor_id = ""
    for line in res_desc.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        if not oid.startswith(".1.3.6.1.2.1.47.1.1.1.1.7."):
            continue
        sid = oid.rsplit(".", 1)[-1]
        val = parts[1].strip()
        if val.startswith("STRING: "):
            val = val[8:].strip('"')
        if val == item:
            sensor_id = sid
            break

    if not sensor_id:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get sensor reading
    res_sensor = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.9.9.91.1.1.1.1.4.%s" % sensor_id
    ], mutates=False)

    reading = None
    for line in res_sensor.stdout.splitlines():
        if "INTEGER: " in line:
            val = line.split("INTEGER: ")[1].strip()
            reading = float(val) / 1000.0
            break

    # Get sensor status
    res_status = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.9.9.91.1.1.1.1.5.%s" % sensor_id
    ], mutates=False)

    state = "1"
    for line in res_status.stdout.splitlines():
        if "INTEGER: " in line:
            state = line.split("INTEGER: ")[1].strip()
            break

    state_map = {
        "1": ("OK", 0),
        "2": ("WARN", 1),
        "3": ("CRIT", 2),
        "4": ("CRIT", 2),
        "5": ("UNKNOWN", 3),
        "6": ("CRIT", 2),
    }

    state_name, state_code = state_map.get(state, ("UNKNOWN", 3))
    if state_name == "UNKNOWN":
        return {
            "changed": False,
            "msg": "Status: " + state_name,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine metric name
    metric_name = "signal_power_dbm"
    if "Transmit" in item or "Tx" in item:
        metric_name = "output_signal_power_dbm"
    elif "Receive" in item or "Rx" in item:
        metric_name = "input_signal_power_dbm"

    # Get thresholds from params (default values as per Checkmk)
    warn_upper = params.get("power_levels_upper", True)
    warn_lower = params.get("power_levels_lower", True)

    # Apply thresholds logic
    final_state = state_code
    if reading != None:
        # Default thresholds if user levels not specified
        upper_warn = 0.0
        upper_crit = 0.0
        lower_warn = -50.0
        lower_crit = -50.0

        if warn_upper == True:
            # Use device levels if available (simplified - use defaults)
            pass
        elif isinstance(warn_upper, list) and len(warn_upper) == 2:
            upper_warn, upper_crit = warn_upper
        elif isinstance(warn_upper, tuple):
            upper_warn, upper_crit = warn_upper

        if warn_lower == True:
            pass
        elif isinstance(warn_lower, list) and len(warn_lower) == 2:
            lower_warn, lower_crit = warn_lower
        elif isinstance(warn_lower, tuple):
            lower_warn, lower_crit = warn_lower

        # Check upper thresholds
        if upper_crit != None and reading >= upper_crit:
            final_state = 2
        elif upper_warn != None and reading >= upper_warn:
            final_state = 1

        # Check lower thresholds
        if lower_crit != None and reading <= lower_crit:
            final_state = 2
        elif lower_warn != None and reading <= lower_warn:
            final_state = 1

    state_names = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    final_state_name = state_names.get(final_state, "UNKNOWN")

    # Build metrics dict
    metrics = {}
    if reading != None:
        metrics[metric_name] = reading

    return {
        "changed": False,
        "msg": "Status: %s, Signal power: %f dBm" % (final_state_name, reading if reading != None else -999),
        "data": {
            "state": final_state_name,
            "metrics": metrics,
            "details": ""
        }
    }
