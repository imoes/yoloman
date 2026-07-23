# Module: lnx_thermal
# Read-only check module for Linux thermal zones

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/sys/class/thermal/thermal_zone*/type", "/sys/class/thermal/thermal_zone*/temp", "/sys/class/thermal/thermal_zone*/trip_points/*_temp", "/sys/class/thermal/thermal_zone*/mode"], mutates=False)
        lines = res.stdout.splitlines()
        zones = _parse_thermal_sections(lines)
        discovery_items = []
        for item, thermal in zones.items():
            if thermal["enabled"]:
                discovery_items.append({
                    "item": item,
                    "params": {"levels": (70.0, 80.0), "device_levels_handling": "devdefault"},
                    "metrics": ["temp"]
                })
        return {"changed": False, "msg": "discovered %d thermal zones" % len(discovery_items),
                "data": {"discovery": discovery_items}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/sys/class/thermal/thermal_zone*/type", "/sys/class/thermal/thermal_zone*/temp", "/sys/class/thermal/thermal_zone*/trip_points/*_temp", "/sys/class/thermal/thermal_zone*/mode"], mutates=False)
    lines = res.stdout.splitlines()
    zones = _parse_thermal_sections(lines)
    data = zones.get(item)

    if data == None or not data["enabled"]:
        return {"changed": False, "msg": "thermal zone not found or disabled: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp = data["temp"]
    warn_level = data.get("passive")
    crit_level = _get_crit_level(data.get("hot"), data.get("critical"))

    # Determine levels for check_temperature logic
    levels = params.get("levels", (70.0, 80.0))
    dev_levels_handling = params.get("device_levels_handling", "devdefault")

    # Apply device levels when enabled
    if dev_levels_handling == "devdefault" or dev_levels_handling == "devdefault_warn":
        if crit_level != None:
            levels = (levels[0] if levels[0] > crit_level else levels[0], crit_level)
        if warn_level != None and levels[0] == levels[1]:
            levels = (warn_level, levels[1])
        elif warn_level != None:
            levels = (warn_level, levels[1])

    warn, crit = levels[0], levels[1]

    # Determine state
    state = "OK"
    if crit != None and temp >= crit:
        state = "CRIT"
    elif warn != None and temp >= warn:
        state = "WARN"

    msg_parts = ["Temperature %s: %f °C" % (item, temp)]
    if warn != None:
        msg_parts.append("(warn at %f °C)" % warn)
    if crit != None:
        msg_parts.append("(crit at %f °C)" % crit)
    if data.get("passive") != None:
        msg_parts.append("passive: %f" % data["passive"])
    if data.get("hot") != None:
        msg_parts.append("hot: %f" % data["hot"])
    if data.get("critical") != None:
        msg_parts.append("critical: %f" % data["critical"])

    metrics = {"temp": temp}
    if warn_level != None:
        metrics["passive"] = warn_level
    if data.get("hot") != None:
        metrics["hot"] = data["hot"]
    if crit_level != None:
        metrics["crit"] = crit_level

    return {"changed": False, "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _parse_thermal_sections(lines):
    # Parse /sys/class/thermal/... entries
    zones = {}
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line.startswith("thermal_zone"):
            i += 1
            continue
        # Extract zone name
        zone_name = line.split("/")[-1]
        i += 1

        # Next lines: mode, then temp, then trip points
        mode_line = ""
        temp_line = ""
        trip_lines = []

        # Collect all lines for this zone until next zone or EOF
        while i < len(lines) and not lines[i].startswith("thermal_zone"):
            line = lines[i].strip()
            if line.endswith("/mode"):
                mode_line = lines[i+1].strip() if i+1 < len(lines) else ""
                i += 2
                continue
            elif line.endswith("/temp"):
                temp_line = lines[i+1].strip() if i+1 < len(lines) else ""
                i += 2
                continue
            elif "trip_points/" in line and line.endswith("_temp"):
                trip_lines.append(lines[i+1].strip() if i+1 < len(lines) else "")
                i += 2
                continue
            i += 1

        # Parse temp
        temp = None
        if temp_line.isdigit():
            temp = float(temp_line) / 1000.0
        elif temp_line == "":
            i += 1
            continue

        # Parse mode
        enabled = True
        if mode_line in ["-", "enabled"]:
            enabled = True
        elif mode_line == "disabled":
            enabled = False

        # Parse trip points: pairs of (trip_point_name, value)
        trip_points = {}
        for j in range(0, len(trip_lines), 2):
            if j+1 >= len(trip_lines):
                break
            trip_name = trip_lines[j].strip().split("/")[-1].replace("_temp", "")
            trip_val = trip_lines[j+1].strip()
            if trip_val.isdigit() and int(trip_val) > 0:
                trip_points[trip_name] = float(trip_val) / 1000.0

        # Map zone name
        formatted_name = _format_item_name(zone_name)
        zones[formatted_name] = {
            "enabled": enabled,
            "temp": temp,
            "passive": trip_points.get("passive"),
            "critical": trip_points.get("critical"),
            "hot": trip_points.get("hot"),
        }

    return zones


def _format_item_name(raw_name):
    return raw_name.replace("thermal_zone", "Zone ")


def _get_crit_level(level0, level1):
    if level0 == None:
        return level1
    if level1 == None:
        return level0
    return min(level0, level1)