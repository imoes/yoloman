def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.2.1.43.9.2.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        # Parse SNMP output into trays: name -> Tray data
        tray_data = {}
        lines = res.stdout.splitlines()
        for line in lines:
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid_end = parts[0].rsplit(".", 1)[-1]
            value = " ".join(parts[1:]).strip()
            if value.startswith("STRING: "):
                value = value[8:].strip('"')
            elif value.startswith("INTEGER: "):
                value = value[9:]
            elif value.startswith("GAUGE: "):
                value = value[7:]
            elif value.startswith("Timeticks: "):
                value = value[11:].strip("()")
            # Map oid_end to field index based on OID position:
            #  base.OIDEnd -> 0 (index), 13->1(name), 12->2(descr), 6->3(status),
            #  3->4(cap_unit), 4->5(cap_max), 5->6(level)
            # We'll accumulate per-tray in a dict indexed by tray_index (oid_end)
            idx = int(oid_end)
            if idx not in tray_data:
                tray_data[idx] = ["", "", "", "", "", "", ""]
            # Field indices: name=13, descr=12, status=6, cap_unit=3, cap_max=4, level=5
            # Determine position relative to base_oid + OIDEnd:
            #   base + 13.* => index 1
            #   base + 12.* => index 2
            #   base + 6.*  => index 3
            #   base + 3.*  => index 4
            #   base + 4.*  => index 5
            #   base + 5.*  => index 6
            if line.startswith(base_oid + ".13."):
                tray_data[idx][1] = value
            elif line.startswith(base_oid + ".12."):
                tray_data[idx][2] = value
            elif line.startswith(base_oid + ".6."):
                tray_data[idx][3] = value
            elif line.startswith(base_oid + ".3."):
                tray_data[idx][4] = value
            elif line.startswith(base_oid + ".4."):
                tray_data[idx][5] = value
            elif line.startswith(base_oid + ".5."):
                tray_data[idx][6] = value

        # Parse trays with same logic as Checkmk's parse_printer_io
        parsed = {}
        for idx, fields in tray_data.items():
            tray_index = str(idx)
            name = fields[1]
            descr = fields[2]
            snmp_status_raw = fields[3]
            capacity_unit_raw = fields[4]
            capacity_max_raw = fields[5]
            level_raw = fields[6]

            snmp_status = int(snmp_status_raw) if snmp_status_raw.isdigit() else 0

            transitioning = bool(snmp_status & 64)
            offline = bool(snmp_status & 32)

            if snmp_status & 16:
                alert = "Critical"
            elif snmp_status & 8:
                alert = "Non-Critical"
            else:
                alert = "None"

            availability_raw = snmp_status % 8
            if availability_raw == 0:
                availability = "Available and idle"
            elif availability_raw == 2:
                availability = "Available and standby"
            elif availability_raw == 4:
                availability = "Available and active"
            elif availability_raw == 6:
                availability = "Available and busy"
            elif availability_raw == 1:
                availability = "Unavailable and on request"
            elif availability_raw == 3:
                availability = "Unavailable because broken"
            else:
                availability = "Unknown"

            if name == "unknown" or not name:
                name = descr if descr else tray_index

            printer_io_units = {
                "-1": "unknown",
                "0": "unknown",
                "1": "unknown",
                "2": "unknown",
                "3": "1/10000 in",
                "4": "micrometers",
                "8": "sheets",
                "16": "feet",
                "17": "meters",
                "18": "items",
                "19": "percent",
            }
            cap_unit = printer_io_units.get(capacity_unit_raw, "unknown")
            if cap_unit != "unknown":
                cap_unit = " " + cap_unit

            parsed[name] = {
                "tray_index": tray_index,
                "name": name,
                "descr": descr,
                "availability": availability,
                "availability_raw": availability_raw,
                "alert": alert,
                "offline": offline,
                "transitioning": transitioning,
                "capacity_unit": cap_unit,
                "capacity_max": int(capacity_max_raw) if capacity_max_raw.isdigit() else 0,
                "level": int(level_raw) if level_raw.isdigit() else 0,
            }

        # Discovery: yield Service(item=name) if description present, capacity_max > 0, and availability ok
        out = []
        for tray_name, tray in parsed.items():
            if tray["descr"] == "":
                continue
            if tray["capacity_max"] == 0:
                continue
            avail_raw = tray["availability_raw"]
            # Skip UNAVAILABLE_BECAUSE_BROKEN (3) and UNKNOWN (5)
            if avail_raw == 3 or avail_raw == 5:
                continue
            out.append({
                "item": tray_name,
                "params": {"capacity_levels": ("fixed", (0.0, 0.0))},
                "metrics": ["remaining_percent"]
            })
        return {"changed": False, "msg": "discovered %d outputs" % len(out),
                "data": {"discovery": out}}

    # CHECK mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.2.1.43.9.2.1"

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    tray_data = {}
    lines = res.stdout.splitlines()
    for line in lines:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid_end = parts[0].rsplit(".", 1)[-1]
        value = " ".join(parts[1:]).strip()
        if value.startswith("STRING: "):
            value = value[8:].strip('"')
        elif value.startswith("INTEGER: "):
            value = value[9:]
        elif value.startswith("GAUGE: "):
            value = value[7:]
        elif value.startswith("Timeticks: "):
            value = value[11:].strip("()")
        idx = int(oid_end)
        if idx not in tray_data:
            tray_data[idx] = ["", "", "", "", "", "", ""]
        if line.startswith(base_oid + ".13."):
            tray_data[idx][1] = value
        elif line.startswith(base_oid + ".12."):
            tray_data[idx][2] = value
        elif line.startswith(base_oid + ".6."):
            tray_data[idx][3] = value
        elif line.startswith(base_oid + ".3."):
            tray_data[idx][4] = value
        elif line.startswith(base_oid + ".4."):
            tray_data[idx][5] = value
        elif line.startswith(base_oid + ".5."):
            tray_data[idx][6] = value

    # Build same parsed dict as discovery
    parsed = {}
    for idx, fields in tray_data.items():
        tray_index = str(idx)
        name = fields[1]
        descr = fields[2]
        snmp_status_raw = fields[3]
        capacity_unit_raw = fields[4]
        capacity_max_raw = fields[5]
        level_raw = fields[6]

        snmp_status = int(snmp_status_raw) if snmp_status_raw.isdigit() else 0

        transitioning = bool(snmp_status & 64)
        offline = bool(snmp_status & 32)

        if snmp_status & 16:
            alert = "Critical"
        elif snmp_status & 8:
            alert = "Non-Critical"
        else:
            alert = "None"

        availability_raw = snmp_status % 8
        if availability_raw == 0:
            availability = "Available and idle"
        elif availability_raw == 2:
            availability = "Available and standby"
        elif availability_raw == 4:
            availability = "Available and active"
        elif availability_raw == 6:
            availability = "Available and busy"
        elif availability_raw == 1:
            availability = "Unavailable and on request"
        elif availability_raw == 3:
            availability = "Unavailable because broken"
        else:
            availability = "Unknown"

        if name == "unknown" or not name:
            name = descr if descr else tray_index

        printer_io_units = {
            "-1": "unknown",
            "0": "unknown",
            "1": "unknown",
            "2": "unknown",
            "3": "1/10000 in",
            "4": "micrometers",
            "8": "sheets",
            "16": "feet",
            "17": "meters",
            "18": "items",
            "19": "percent",
        }
        cap_unit = printer_io_units.get(capacity_unit_raw, "unknown")
        if cap_unit != "unknown":
            cap_unit = " " + cap_unit

        parsed[name] = {
            "tray_index": tray_index,
            "name": name,
            "descr": descr,
            "availability": availability,
            "availability_raw": availability_raw,
            "alert": alert,
            "offline": offline,
            "transitioning": transitioning,
            "capacity_unit": cap_unit,
            "capacity_max": int(capacity_max_raw) if capacity_max_raw.isdigit() else 0,
            "level": int(level_raw) if level_raw.isdigit() else 0,
        }

    tray = parsed.get(item)
    if tray == None:
        return {"changed": False, "msg": "output tray not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build summary and details
    msg_parts = []
    details_parts = []
    state = "OK"

    # Description
    if tray["descr"]:
        msg_parts.append(tray["descr"])
        details_parts.append("Description: " + tray["descr"])

    # Offline
    if tray["offline"]:
        if state == "OK":
            state = "CRIT"
        msg_parts.append("Offline")
        details_parts.append("Status: Offline")

    # Transitioning
    if tray["transitioning"]:
        msg_parts.append("Transitioning")
        details_parts.append("Transitioning: true")

    # Availability status
    avail_name = tray["availability"].replace("and", "&").replace(" ", "")
    msg_parts.append("Status: " + avail_name)
    details_parts.append("Status: " + tray["availability"])

    # Alerts
    alert_msg = "Alerts: " + tray["alert"]
    msg_parts.append(alert_msg)
    details_parts.append(alert_msg)

    # State mapping for availability
    if tray["availability_raw"] == 1:  # Unavailable and on request
        if state == "OK":
            state = "WARN"
    elif tray["availability_raw"] == 3:  # Unavailable because broken
        state = "CRIT"
    elif tray["availability_raw"] == 5:  # Unknown
        state = "UNKNOWN"

    # Alert mapping
    if tray["alert"] == "Non-Critical" and state == "OK":
        state = "WARN"
    elif tray["alert"] == "Critical":
        state = "CRIT"

    # Capacity info
    level = tray["level"]
    capacity_max = tray["capacity_max"]
    cap_unit = tray["capacity_unit"]

    metrics = {}

    if level in [-1, -2] or level < -3:
        # skip remaining info when level is unknown or not limited
        return {"changed": False, "msg": ", ".join(msg_parts),
                "data": {"state": state, "metrics": metrics, "details": "; ".join(details_parts)}}

    if capacity_max in [-2, -1, 0]:
        if cap_unit != " unknown":
            msg_parts.append("Capacity: " + str(level) + cap_unit)
            details_parts.append("Capacity: " + str(level) + cap_unit)
        return {"changed": False, "msg": ", ".join(msg_parts),
                "data": {"state": state, "metrics": metrics, "details": "; ".join(details_parts)}}

    if cap_unit != " unknown":
        msg_parts.append("Maximal capacity: " + str(capacity_max) + cap_unit)
        details_parts.append("Maximal capacity: " + str(capacity_max) + cap_unit)

    # Remaining percentage
    if capacity_max == 0:
        remaining_pct = 0.0
    else:
        remaining_pct = 100.0 * level / capacity_max

    metrics["remaining_percent"] = remaining_pct

    # Apply levels (fixed 0.0,0.0 by default)
    capacity_levels = params.get("capacity_levels", ("fixed", (0.0, 0.0)))
    if capacity_levels[0] == "fixed":
        warn, crit = capacity_levels[1]
    else:
        warn, crit = 0.0, 0.0

    # For lower levels: OK if >= warn/crit, WARN if < warn, CRIT if < crit
    if remaining_pct < crit:
        state = "CRIT"
    elif remaining_pct < warn:
        if state != "CRIT":
            state = "WARN"

    msg_parts.append("Remaining: %f%%" % remaining_pct)
    details_parts.append("Remaining: %f%%" % remaining_pct)

    return {"changed": False, "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": "; ".join(details_parts)}}