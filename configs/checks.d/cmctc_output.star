def main(ctx, params):
    # === Constants (top level for Starlark) ===
    _TABLES = ["3", "4", "5", "6"]
    _OID_BASE = ".1.3.6.1.4.1.2606.4.2.%s.6.2.1"

    # SNMP type map: ID -> (description, unit, perfkey)
    TYPE_MAP = {
        "4": ("Door locking TS8 Ergoform", "", None),
        "5": ("Universal lock 1 lock with power", "", None),
        "6": ("Universal lock 2 unlock with power", "", None),
        "7": ("Fan relay", "", None),
        "8": ("Fan controlled", "", None),
        "9": ("Universal relay output", "", None),
        "10": ("Room door lock", "", None),
        "11": ("Power output", "", None),
        "12": ("Door lock with Master key", "", None),
        "13": ("Door lock FR(i)", "", None),
        "14": ("Setpoint", "", None),
        "15": ("Setpoint temperature monitoring", " °C", "temp"),
        "16": ("Hysteresis of setpoint", "", None),
        "17": ("Command for remote control of RCT", "", None),
        "18": ("Relay", "", None),
        "19": ("High setpoint current monitoring", " A", "current"),
        "20": ("Low setpoint current monitoring", " A", "current"),
        "21": ("Retpoint temperature RTT", " °C", "temp"),
        "22": ("Setpoint temperature monitoring RTT", " °C", "temp"),
        "23": ("Power output 20A", " A", "current"),
        "24": ("Door magnet automatic door release", "", None),
        "30": ("Control mode", "", None),
        "31": ("Min fan speed", " RPM", "rpm"),
        "32": ("Min delta T", " °C", "temp"),
        "33": ("Max delta T", " °C", "temp"),
        "34": ("PID controller", "", None),
        "35": ("PID controller", "", None),
        "36": ("PID controller", "", None),
        "37": ("Flowrate flowmeter", " l/min", "flow"),
        "38": ("Cw value of water", "", ""),
        "39": ("deltaT", " °C", "temp"),
        "40": ("Control mode", "", None),
        "42": ("Setpoint high voltage PSM", "V", "voltage"),
        "43": ("Setpoint low voltage PSM", "V", "voltage"),
        "44": ("Setpoint high current PSM", "A", "current"),
        "45": ("Setpoint low current PSM", "A", "current"),
        "46": ("Command PSM", "", None),
    }

    # SNMP status map
    STATUS_MAP = {
        "1": "not available",
        "2": "lost",
        "3": "changed",
        "4": "ok",
        "5": "off",
        "6": "on",
        "7": "set off",
        "8": "set on",
    }

    # Command/config/timeout maps (only needed if used)
    COMMAND_MAP = {"1": "off", "2": "on", "3": "lock", "4": "unlock", "5": "unlock delay"}
    CONFIG_MAP = {"1": "disable remote control", "2": "enable remote control"}
    TIMEOUT_MAP = {"1": "stay", "2": "off", "3": "on"}

    # === STATE MAP for results (OK/WARN/CRIT/UNKNOWN) ===
    STATE_MAP = {
        "ok": "OK",
        "on": "OK",
        "set off": "OK",
        "set on": "OK",
        "changed": "WARN",
        "lost": "CRIT",
        "off": "CRIT",
        "not available": "UNKNOWN",
    }

    # === DISCOVERY MODE ===
    if params.get("_discover"):
        # Probe all tables
        all_items = []
        for table_idx in _TABLES:
            base_oid = _OID_BASE % table_idx
            # Walk the full table using snmpwalk
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"),
                base_oid
            ], mutates=False)
            if res.rc != 0:
                continue  # Skip tables that fail (non-fatal in discovery)

            # Parse snmpwalk output: each line is "<oid> = <type>: <value>"
            # We need to reassemble 9-oid rows (index, type_id, description, status, value, command, config, delay, timeout_action)
            # Each OID suffix is in sequence: 1,2,3,4,5,6,7,8,9 per entry.
            lines = res.stdout.splitlines()
            entry = []
            for line in lines:
                # Split into OID and value parts
                parts = line.strip().split(" = ")
                if len(parts) != 2:
                    continue
                value_str = parts[1].strip()
                # Extract value (strip type prefix if present: "INTEGER: ", "STRING: ", etc.)
                if value_str.startswith("STRING: "):
                    value = value_str[8:].strip('"')
                elif value_str.startswith("INTEGER: "):
                    value = value_str[9:]
                elif value_str.startswith(" Gauge32: "):
                    value = value_str[10:]
                else:
                    value = value_str

                entry.append(value)

                # Every 9 values we have a complete row
                if len(entry) == 9:
                    index, sensor_type_id, description, status, value, command, config, delay, timeout_action = entry

                    # Skip if status is "not available" (1)
                    if status == "1":
                        entry = []
                        continue

                    sensor_type, unit, perfkey = TYPE_MAP.get(sensor_type_id, ("Unknown output", "", None))

                    name = "%s %s.%s" % (sensor_type, table_idx, index)

                    all_items.append({
                        "item": name,
                        "params": {},
                        "metrics": [perfkey] if perfkey else []
                    })
                    entry = []

        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(all_items),
            "data": {"discovery": all_items}
        }

    # === CHECK MODE ===
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch all sensor data (same logic as discovery, but stop when we find our item)
    sensor_data = None
    for table_idx in _TABLES:
        base_oid = _OID_BASE % table_idx
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid
        ], mutates=False)
        if res.rc != 0:
            continue

        lines = res.stdout.splitlines()
        entry = []
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            value_str = parts[1].strip()
            if value_str.startswith("STRING: "):
                value = value_str[8:].strip('"')
            elif value_str.startswith("INTEGER: "):
                value = value_str[9:]
            elif value_str.startswith(" Gauge32: "):
                value = value_str[10:]
            else:
                value = value_str

            entry.append(value)

            if len(entry) == 9:
                index, sensor_type_id, description, status, value, command, config, delay, timeout_action = entry

                if status == "1":
                    entry = []
                    continue

                sensor_type, unit, perfkey = TYPE_MAP.get(sensor_type_id, ("Unknown output", "", None))
                name = "%s %s.%s" % (sensor_type, table_idx, index)

                if name == item:
                    # Build parsed sensor dict
                    sensor_data = {
                        "status": STATUS_MAP.get(status, "unknown"),
                        "value": int(value),
                        "unit": unit,
                        "perfkey": perfkey,
                        "command": COMMAND_MAP.get(command),
                        "config": CONFIG_MAP.get(config),
                        "delay": int(delay),
                        "timeout_action": TIMEOUT_MAP.get(timeout_action),
                        "description": description
                    }
                    break
                entry = []
        if sensor_data != None:
            break

    if sensor_data == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine state
    status = sensor_data["status"]
    state = STATE_MAP.get(status, "UNKNOWN")
    infotext = "[%s] %d%s, %s" % (
        sensor_data["description"],
        sensor_data["value"],
        sensor_data["unit"],
        status
    )
    details = "Command: %s, Config: %s, Delay: %d, Timeout action: %s" % (
        str(sensor_data["command"]),
        str(sensor_data["config"]),
        sensor_data["delay"],
        str(sensor_data["timeout_action"])
    )

    metrics = {}
    if sensor_data["perfkey"] != None:
        metrics[sensor_data["perfkey"]] = sensor_data["value"]

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details
        }
    }
