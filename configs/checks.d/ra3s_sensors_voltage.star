def main(ctx, params):
    # discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.20916.1.13.1.2.1"
        ], mutates=False)

        sensor_type_found = False
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" = ", 1)
            if len(parts) < 2:
                continue
            val_part = parts[1].strip()
            words = val_part.split()
            numeric_count = 0
            for w in words:
                stripped = ""
                for c in w:
                    if c.isdigit() or c == '.':
                        stripped = stripped + c
                if stripped != "":
                    is_number = True
                    dot_count = 0
                    for ch in stripped:
                        if ch == '.':
                            dot_count = dot_count + 1
                    if dot_count > 1:
                        is_number = False
                    else:
                        alt = stripped.replace(".", "")
                        if not alt.isdigit():
                            is_number = False
                    if is_number:
                        numeric_count = numeric_count + 1
            if numeric_count >= 4:
                sensor_type_found = True
                break

        if sensor_type_found:
            return {
                "changed": False,
                "msg": "discovered 1 voltage sensor",
                "data": {
                    "discovery": [
                        {"item": "Sensor", "params": {"voltage": [4, 6]}, "metrics": ["voltage"]}
                    ]
                }
            }
        else:
            return {
                "changed": False,
                "msg": "no voltage sensor found",
                "data": {"discovery": []}
            }

    # check mode
    item = params.get("item", "")
    if item != "Sensor":
        return {
            "changed": False,
            "msg": "item not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.20916.1.13.1.2.1.3"
    ], mutates=False)

    voltage_mv = None
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        val_part = parts[1].strip()
        if val_part.startswith("INTEGER:"):
            val_str = val_part.split(":", 1)[1].strip()
            if val_str.isdigit():
                voltage_mv = int(val_str)
                break

    if voltage_mv == None:
        return {
            "changed": False,
            "msg": "no voltage reading available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    voltage = float(voltage_mv) / 1000.0

    thresholds = params.get("voltage", [4, 6])
    warn_low = thresholds[0] if len(thresholds) > 0 else 4.0
    crit_low = thresholds[1] if len(thresholds) > 1 else 6.0

    if voltage >= crit_low:
        state = "CRIT"
    elif voltage >= warn_low:
        state = "WARN"
    else:
        state = "OK"

    msg = "Voltage: %f V" % voltage
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"voltage": voltage},
            "details": ""
        }
    }