# ===== Module-level constants =====
SNMP_BASE = ".1.3.6.1.4.1.2272.1.101.1.1.4.1"
SNMP_OIDS = ["3", "4", "5", "6"]  # description, operStatus, operSpeed, operSpeedRpm

MAP_FAN_STATUS = {
    "1": ("UNKNOWN", "unknown - status can not be determined"),
    "2": ("OK", "up - present and supplying power"),
    "3": ("CRIT", "down - present, but failure indicated"),
}

MAP_FAN_SPEED = {
    "1": "low",
    "2": "medium",
    "3": "high",
}

# Default params from Checkmk plugin
DEFAULT_PARAMS = {
    "lower": [2000, 1000],  # [warn, crit]
    "upper": [8000, 8400],  # [warn, crit]
    "output_metrics": True,
}


def _get_system_oid(ctx, params):
    """Check if host is a NetExtreme device via sysObjectID."""
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                  mutates=False)
    if res.rc != 0:
        return None
    # Output format: ".1.3.6.1.2.1.1.2.0 = OID: <oid>"
    lines = res.stdout.strip().splitlines()
    if len(lines) < 1:
        return None
    parts = lines[0].split(" = OID: ")
    if len(parts) < 2:
        return None
    oid = parts[1].strip()
    return oid


def _walk_snmp(ctx, params, base_oid):
    """Walk SNMP tree and return list of row dicts."""
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), base_oid],
                  mutates=False)
    if res.rc != 0:
        return []

    rows = []
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        # Format: <oid> = <type>: <value>
        eq_idx = line.find(" = ")
        if eq_idx < 0:
            continue
        oid_part = line[:eq_idx].strip()
        val_part = line[eq_idx + 3:].strip()

        # Extract the leaf OID suffix after base
        suffix = oid_part[len(base_oid):]
        if suffix.startswith("."):
            suffix = suffix[1:]

        # Split value: "<TYPE>: <value>"
        colon_idx = val_part.find(": ")
        if colon_idx < 0:
            value = val_part.strip()
        else:
            value = val_part[colon_idx + 2:].strip()

        rows.append({"oid_suffix": suffix, "value": value})

    return rows


def main(ctx, params):
    # Check SNMP availability
    system_oid = _get_system_oid(ctx, params)
    if system_oid == None:
        if params.get("_discover"):
            return {"changed": False, "msg": "SNMP walk failed or no sysObjectID",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "SNMP walk failed or no sysObjectID",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Detect NetExtreme devices
    is_netextreme = (system_oid.startswith(".1.3.6.1.4.1.1916.2") or
                     system_oid.startswith(".1.3.6.1.4.1.2272.2") or
                     system_oid.startswith(".1.3.6.1.4.1.2272.202") or
                     system_oid.startswith(".1.3.6.1.4.1.2272.209") or
                     system_oid.startswith(".1.3.6.1.4.1.2272.220") or
                     system_oid.startswith(".1.3.6.1.4.1.2272.212"))

    # DISCOVERY MODE
    if params.get("_discover"):
        if not is_netextreme:
            return {"changed": False, "msg": "discovered 0 items (not NetExtreme)",
                    "data": {"discovery": []}}

        rows = _walk_snmp(ctx, params, SNMP_BASE)
        # Build section: key by description (column 3 / OID suffix "1")
        fans = {}
        for row in rows:
            suffix = row["oid_suffix"]
            if not suffix:
                continue

            # Split suffix into column index (1-based)
            idx_parts = suffix.split(".")
            if len(idx_parts) < 2:
                continue
            idx = int(idx_parts[-1])  # instance index
            col = int(idx_parts[-2])   # column index

            # We need to group by instance index (4 columns per instance)
            if idx not in fans:
                fans[idx] = [None, None, None, None]
            fans[idx][col-1] = row["value"]

        discovery = []
        for idx in sorted(fans.keys()):
            row = fans[idx]
            if len(row) < 4:
                continue
            description = row[0] if row[0] else ("Fan " + str(idx))
            if description == None or description == "":
                continue
            discovery.append({
                "item": description,
                "params": DEFAULT_PARAMS,
                "metrics": ["speed_rpm"] if row[3] and row[3].isdigit() else [],
            })

        return {"changed": False, "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE
    item = params.get("item", "")
    if not is_netextreme:
        return {"changed": False, "msg": "not a NetExtreme device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = _walk_snmp(ctx, params, SNMP_BASE)

    # Build section dict
    section = {}
    for row in rows:
        suffix = row["oid_suffix"]
        if not suffix:
            continue
        idx_parts = suffix.split(".")
        if len(idx_parts) < 2:
            continue
        idx = int(idx_parts[-1])
        col = int(idx_parts[-2])
        if idx not in section:
            section[idx] = [None, None, None, None]
        section[idx][col-1] = row["value"]

    # Find matching item
    found = None
    for idx in section:
        row = section[idx]
        description = row[0] if row[0] else ("Fan " + str(idx))
        if description == item:
            found = row
            break

    if found == None:
        return {"changed": False, "msg": "fan item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    operational_status = found[1] if found[1] else "1"
    operational_speed_raw = found[2] if found[2] else "1"
    operational_speed_rpm_str = found[3] if found[3] else ""

    # Determine status state and message
    status_map = MAP_FAN_STATUS.get(operational_status,
                                    ("UNKNOWN", "Unknown fan status: " + str(operational_status)))
    state = status_map[0]
    state_readable = status_map[1]
    fan_speed = MAP_FAN_SPEED.get(operational_speed_raw, "unknown")

    # Process RPM if available
    metrics = {}
    rpm = None
    if operational_speed_rpm_str.isdigit():
        rpm = int(operational_speed_rpm_str)
        metrics["speed_rpm"] = rpm

        # Apply fan thresholds (Checkmk default: lower=[2000,1000], upper=[8000,8400])
        p = params.get("params", DEFAULT_PARAMS)
        lower_warn = p.get("lower", DEFAULT_PARAMS["lower"])[0]
        lower_crit = p.get("lower", DEFAULT_PARAMS["lower"])[1]
        upper_warn = p.get("upper", DEFAULT_PARAMS["upper"])[0]
        upper_crit = p.get("upper", DEFAULT_PARAMS["upper"])[1]

        # Lower thresholds (min acceptable speed)
        if rpm <= lower_crit:
            state = "CRIT"
        elif rpm <= lower_warn and state not in ("CRIT",):
            state = "WARN"
        # Upper thresholds (max acceptable speed)
        if rpm >= upper_crit:
            state = "CRIT"
        elif rpm >= upper_warn and state not in ("CRIT",):
            state = "WARN"

        if p.get("output_metrics", True):
            metrics["speed_rpm"] = rpm

    # Build message
    msg = "Fan status: " + state_readable + "; Fan speed: " + fan_speed
    if rpm != None:
        msg += "; Speed: " + str(rpm) + " RPM"

    # Determine final state priority
    if operational_status == "3":
        state = "CRIT"
    elif operational_status == "2":
        if state not in ("CRIT",):
            state = "OK"
    else:
        state = "UNKNOWN"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
