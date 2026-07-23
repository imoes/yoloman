def main(ctx, params):
    # Constants for sensor mapping
    CMCTC_LCP_SENSORS = {
        "4": (None, "access"),
        "12": (None, "humidity"),
        "13": ("normally open", "user"),
        "14": ("normally closed", "user"),
        "23": (None, "flow"),
        "30": (None, "current"),
        "31": (None, "status"),
        "32": (None, "position"),
        "40": ("1", "blower"),
        "41": ("2", "blower"),
        "42": ("3", "blower"),
        "43": ("4", "blower"),
        "44": ("5", "blower"),
        "45": ("6", "blower"),
        "46": ("7", "blower"),
        "47": ("8", "blower"),
        "48": ("Server in 1", "temp"),
        "49": ("Server out 1", "temp"),
        "50": ("Server in 2", "temp"),
        "51": ("Server out 2", "temp"),
        "52": ("Server in 3", "temp"),
        "53": ("Server out 3", "temp"),
        "54": ("Server in 4", "temp"),
        "55": ("Server out 4", "temp"),
        "56": ("Overview Server in", "temp"),
        "57": ("Overview Server out", "temp"),
        "58": ("Water in", "temp"),
        "59": ("Water out", "temp"),
        "60": (None, "flow"),
        "61": (None, "blowergrade"),
        "62": (None, "regulator"),
    }
    TREES = ["3", "4", "5", "6"]

    # State mapping: status code -> (state, text)
    MAP_SENSOR_STATE = {
        "1": (3, "not available"),
        "2": (2, "lost"),
        "3": (1, "changed"),
        "4": (0, "ok"),
        "5": (2, "off"),
        "6": (0, "on"),
        "7": (1, "warning"),
        "8": (2, "too low"),
        "9": (2, "too high"),
        "10": (2, "error"),
    }
    MAP_UNIT = {
        "access": "",
        "current": " A",
        "status": "",
        "position": "",
        "temp": " °C",
        "blower": " RPM",
        "blowergrade": "",
        "humidity": "%",
        "flow": " l/min",
        "regulator": "%",
        "user": "",
    }

    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        items = []
        for tree in TREES:
            # Fetch description table
            desc_oid = ".1.3.6.1.4.1.2606.4.2.%s.7.2.1" % tree
            desc_res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), desc_oid
            ], mutates=False)

            # Parse descriptions
            descriptions = {}
            for line in desc_res.stdout.splitlines():
                parts = line.strip().split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_path = parts[0].strip()
                value = parts[1].strip()
                oid_parts = oid_path.split(".")
                if len(oid_parts) < 20:
                    continue
                t = oid_parts[6]
                idx_str = oid_parts[19]
                if t == tree and value != None and value != "" and idx_str.isdigit():
                    idx = int(idx_str)
                    descriptions[idx] = value

            # Fetch sensor table
            sensor_oid = ".1.3.6.1.4.1.2606.4.2.%s.5.2.1" % tree
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), sensor_oid
            ], mutates=False)

            # Parse sensor table
            table = {}  # idx -> {typeid, status, reading, high, low, warn}
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_path = parts[0].strip()
                value = parts[1].strip()
                oid_parts = oid_path.split(".")
                if len(oid_parts) < 20:
                    continue
                t = oid_parts[6]
                field_str = oid_parts[15]
                idx_str = oid_parts[16]
                if t != tree or not field_str.isdigit() or not idx_str.isdigit():
                    continue
                field = int(field_str)
                idx = int(idx_str)
                if not (idx in table):
                    table[idx] = {}
                field_map = {
                    1: "index",
                    2: "typeid",
                    4: "status",
                    5: "reading",
                    6: "high",
                    7: "low",
                    8: "warn",
                }
                field_name = field_map.get(field, "")
                if field_name != "" and value != None and value != "":
                    table[idx][field_name] = value

            # Process sensors
            for idx in table:
                data = table[idx]
                typeid = data.get("typeid", "")
                if typeid == "":
                    continue
                sensor_spec = CMCTC_LCP_SENSORS.get(typeid)
                if sensor_spec == None:
                    continue
                if sensor_spec[1] != "flow":
                    continue
                # Build item name
                item = "%s - %s.%s" % (sensor_spec[0], tree, idx) if sensor_spec[0] != None else "%s.%s" % (tree, idx)
                items.append({
                    "item": item,
                    "params": {},
                    "metrics": ["flow"]
                })

        return {
            "changed": False,
            "msg": "discovered %d flow sensors" % len(items),
            "data": {"discovery": items}
        }

    # ===== CHECK MODE =====
    item = params.get("item", "")

    # Extract tree and index from item (format: "tree.index" or "name - tree.index")
    tree_idx = item
    if item.find(" - ") >= 0:
        tree_idx = item.split(" - ")[1]

    parts = tree_idx.split(".")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    tree = parts[0]
    idx_str = parts[1]

    if not (tree in TREES):
        return {
            "changed": False,
            "msg": "invalid tree in item: " + tree,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch description table
    desc_oid = ".1.3.6.1.4.1.2606.4.2.%s.7.2.1" % tree
    desc_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), desc_oid
    ], mutates=False)

    descriptions = {}
    for line in desc_res.stdout.splitlines():
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_path = parts[0].strip()
        value = parts[1].strip()
        oid_parts = oid_path.split(".")
        if len(oid_parts) < 20:
            continue
        t = oid_parts[6]
        idx_str_desc = oid_parts[19]
        if t == tree and value != None and value != "" and idx_str_desc.isdigit():
            idx = int(idx_str_desc)
            descriptions[idx] = value

    # Fetch sensor table
    sensor_oid = ".1.3.6.1.4.1.2606.4.2.%s.5.2.1" % tree
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), sensor_oid
    ], mutates=False)

    table = {}  # idx -> {typeid, status, reading, high, low, warn}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_path = parts[0].strip()
        value = parts[1].strip()
        oid_parts = oid_path.split(".")
        if len(oid_parts) < 20:
            continue
        t = oid_parts[6]
        field_str = oid_parts[15]
        idx_str_s = oid_parts[16]
        if t != tree or not field_str.isdigit() or not idx_str_s.isdigit():
            continue
        field = int(field_str)
        idx = int(idx_str_s)
        if not (idx in table):
            table[idx] = {}
        field_map = {
            1: "index",
            2: "typeid",
            4: "status",
            5: "reading",
            6: "high",
            7: "low",
            8: "warn",
        }
        field_name = field_map.get(field, "")
        if field_name != "" and value != None and value != "":
            table[idx][field_name] = value

    # Find the sensor
    found_sensor = None
    for idx in table:
        data = table[idx]
        typeid = data.get("typeid", "")
        if typeid == "":
            continue
        sensor_spec = CMCTC_LCP_SENSORS.get(typeid)
        if sensor_spec == None:
            continue
        if sensor_spec[1] != "flow":
            continue
        item_name = "%s - %s.%s" % (sensor_spec[0], tree, idx) if sensor_spec[0] != None else "%s.%s" % (tree, idx)
        if item_name == item:
            idx_int = int(idx_str)
            description = descriptions.get(idx_int, "")
            reading_val = data.get("reading", "0")
            high_val = data.get("high", "0")
            low_val = data.get("low", "0")
            warn_val = data.get("warn", "0")
            found_sensor = {
                "status": data.get("status", "0"),
                "reading": float(reading_val) if reading_val.replace(".","").lstrip("-").isdigit() else 0.0,
                "high": float(high_val) if high_val.replace(".","").lstrip("-").isdigit() else 0.0,
                "low": float(low_val) if low_val.replace(".","").lstrip("-").isdigit() else 0.0,
                "warn": float(warn_val) if warn_val.replace(".","").lstrip("-").isdigit() else 0.0,
                "description": description,
                "type_": "flow"
            }
            break

    if found_sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    sensor = found_sensor
    unit = MAP_UNIT.get(sensor["type_"], "")
    infotext = ""
    if sensor["description"] != "":
        infotext = "[%s] " % sensor["description"]

    # Status mapping
    status_code = sensor["status"]
    state, extra_info = MAP_SENSOR_STATE.get(status_code, (3, "unknown"))
    cm_state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state_text = cm_state_map.get(state, "UNKNOWN")
    summary = "%s%d%s" % (infotext, int(sensor["reading"]), unit)

    # Check levels
    extra_state = state
    metrics = {"flow": sensor["reading"]}

    # Get levels from params or use device defaults
    warn = None
    crit = None
    if params != None:
        if type(params) == "list" and len(params) >= 2:
            warn_str = str(params[0])
            crit_str = str(params[1])
            warn = float(warn_str) if warn_str.replace(".","").lstrip("-").isdigit() else None
            crit = float(crit_str) if crit_str.replace(".","").lstrip("-").isdigit() else None
        elif type(params) == "dict":
            warn_val = params.get("warn", "0")
            crit_val = params.get("crit", "0")
            warn_str = str(warn_val)
            crit_str = str(crit_val)
            warn = float(warn_str) if warn_str.replace(".","").lstrip("-").isdigit() else None
            crit = float(crit_str) if crit_str.replace(".","").lstrip("-").isdigit() else None

    if warn != None and crit != None:
        if sensor["reading"] >= crit:
            extra_state = 2
            extra_info = extra_info + " (crit at %d%s)" % (crit, unit)
        elif sensor["reading"] >= warn:
            extra_state = 1
            extra_info = extra_info + " (warn at %d%s)" % (warn, unit)
    else:
        # Check device default levels
        if sensor["low"] != 0 or sensor["warn"] != 0 or sensor["high"] != 0:
            if sensor["low"] < sensor["high"]:
                if sensor["reading"] >= sensor["high"]:
                    extra_state = 2
                    extra_info = extra_info + " (device crit at %d%s)" % (sensor["high"], unit)
                elif sensor["reading"] >= sensor["warn"]:
                    extra_state = 1
                    extra_info = extra_info + " (device warn at %d%s)" % (sensor["warn"], unit)

    return {
        "changed": False,
        "msg": summary + (" " + extra_info if extra_info != "" else ""),
        "data": {
            "state": cm_state_map.get(extra_state, "UNKNOWN"),
            "metrics": metrics,
            "details": ""
        },
    }