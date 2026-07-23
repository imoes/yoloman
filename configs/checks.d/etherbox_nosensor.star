# ===== starlark check module: etherbox_nosensor =====
# Translated from Checkmk check: checkmk.etherbox_nosensor
# Read-only: no mutations, always changed=False

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Fetch unit of measurement (OID .1.3.6.1.4.1.14848.2.1.1.3)
        unit_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.14848.2.1.1.3"
        ], mutates=False)
        # Fetch sensor data (OID .1.3.6.1.4.1.14848.2.1.2.1)
        sensor_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.14848.2.1.2.1"
        ], mutates=False)

        # Parse unit_of_measurement (expected format: "1.3.6.1.4.1.14848.2.1.1.3 = INTEGER: 0")
        unit_of_measurement = "c"  # default
        for line in unit_res.stdout.splitlines():
            if line.strip() == "" or line.find("=") == -1:
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) == 2 and parts[1].strip().startswith("INTEGER: "):
                val_str = parts[1].strip()[len("INTEGER: "):].strip()
                if val_str == "0":
                    unit_of_measurement = "c"
                elif val_str == "1":
                    unit_of_measurement = "f"
                elif val_str == "2":
                    unit_of_measurement = "k"
                break

        # Parse sensor data entries
        # Format: OID.end = INTEGER: index;STRING:name;INTEGER:type;INTEGER:status;INTEGER:value*10
        # Example: .1.3.6.1.4.1.14848.2.1.2.1.1.1 = INTEGER: 1;STRING:Port 1;INTEGER:0;INTEGER:1;INTEGER:0
        sensor_data = {}  # index -> {type -> SensorData}
        for line in sensor_res.stdout.splitlines():
            if line.strip() == "" or line.find("=") == -1:
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            # Extract last OID component as index (after last dot)
            oid_part = parts[0].strip()
            last_dot = oid_part.rfind(".")
            if last_dot == -1:
                continue
            index_str = oid_part[last_dot + 1:].strip()

            # Parse value part: "INTEGER: index;STRING:name;INTEGER:type;INTEGER:status;INTEGER:value*10"
            value_part = parts[1].strip()
            if not value_part.startswith("INTEGER: "):
                continue
            # Remove leading "INTEGER: " and split by semicolons
            rest = value_part[len("INTEGER: "):].split(";")
            if len(rest) < 5:
                continue
            # Skip first INTEGER (index), second is STRING:name, third INTEGER:type, fourth INTEGER:status, fifth INTEGER:value*10
            name = ""
            sensor_type = ""
            value = 0
            # Parse name
            name_raw = rest[1].strip()
            if name_raw.startswith("STRING: "):
                name = name_raw[len("STRING: "):].strip().strip('"')
            else:
                name = name_raw
            # Parse sensor type
            type_raw = rest[2].strip()
            if type_raw.startswith("INTEGER: "):
                sensor_type = type_raw[len("INTEGER: "):].strip()
            else:
                sensor_type = type_raw
            # Parse value
            val_raw = rest[4].strip()
            if val_raw.startswith("INTEGER: "):
                val_str = val_raw[len("INTEGER: "):].strip()
            else:
                val_str = val_raw
            value = int(val_str) if val_str.lstrip("-").isdigit() else 0

            if index_str not in sensor_data:
                sensor_data[index_str] = {}
            sensor_data[index_str][sensor_type] = {"name": name, "value": value}

        # Discover items with sensor_type "0" (no sensor)
        out = []
        for index, index_data in sensor_data.items():
            for sensor_type, data in index_data.items():
                if sensor_type == "0":
                    out.append({
                        "item": index + "." + sensor_type,
                        "params": {},
                        "metrics": []
                    })
        return {
            "changed": False,
            "msg": "discovered %d no-sensor items" % len(out),
            "data": {"discovery": out}
        }

    # CHECK MODE
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch sensor data (same OID as discovery)
    sensor_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.14848.2.1.2.1"
    ], mutates=False)

    # Parse sensor data (same structure as discovery)
    sensor_data = {}
    for line in sensor_res.stdout.splitlines():
        if line.strip() == "" or line.find("=") == -1:
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        last_dot = oid_part.rfind(".")
        if last_dot == -1:
            continue
        index_str = oid_part[last_dot + 1:].strip()

        value_part = parts[1].strip()
        if not value_part.startswith("INTEGER: "):
            continue
        rest = value_part[len("INTEGER: "):].split(";")
        if len(rest) < 5:
            continue
        # Parse name
        name_raw = rest[1].strip()
        if name_raw.startswith("STRING: "):
            name = name_raw[len("STRING: "):].strip().strip('"')
        else:
            name = name_raw
        # Parse sensor type
        type_raw = rest[2].strip()
        if type_raw.startswith("INTEGER: "):
            sensor_type = type_raw[len("INTEGER: "):].strip()
        else:
            sensor_type = type_raw
        # Parse value
        val_raw = rest[4].strip()
        if val_raw.startswith("INTEGER: "):
            val_str = val_raw[len("INTEGER: "):].strip()
        else:
            val_str = val_raw
        value = int(val_str) if val_str.lstrip("-").isdigit() else 0

        if index_str not in sensor_data:
            sensor_data[index_str] = {}
        sensor_data[index_str][sensor_type] = {"name": name, "value": value}

    # Extract item_index and item_type from item (format "index.sensor_type")
    parts = item.split(".")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    item_index = parts[0]
    item_type = parts[1]

    if item_index not in sensor_data or item_type not in sensor_data[item_index]:
        return {
            "changed": False,
            "msg": "Sensor not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    data = sensor_data[item_index][item_type]

    # Return OK with summary "[name] no sensor connected"
    summary = "[%s] no sensor connected" % data["name"]
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }
