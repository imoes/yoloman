
# OID bases for SNMP walks
MEDIA_ACCESS_BASE = ".1.3.6.1.4.1.14851.3.1.6.2.1"
CONTROLLER_BASE = ".1.3.6.1.4.1.14851.3.1.12.2.1"

# Type mapping (string to string)
TYPE_MAP = {
    "0": "unknown",
    "1": "worm drive",
    "2": "magneto optical drive",
    "3": "tape drive",
    "4": "dvd drive",
    "5": "cdrom drive",
}

# Clean state mapping
CLEAN_MAP = {
    "0": "unknown",
    "1": "true",
    "2": "false",
}

# Operational status and availability mapping for device state
AVAILABILITY_MAP = {
    "2": "online",
    "3": "online",
    "4": "offline",
    "5": "offline",
    "6": "offline",
    "7": "offline",
    "8": "offline",
}

STATUS_MAP = {
    "2": "ok",
    "3": "ok",
    "4": "degraded",
    "5": "degraded",
    "6": "error",
    "7": "error",
    "8": "error",
}


def _parse_device_name(name):
    """Extract the last non-whitespace part as device identifier."""
    parts = name.strip().split()
    if len(parts) >= 1:
        return parts[-1]
    return name.strip()


def _walk_snmp(ctx, base_oid, community, host):
    """Walk an SNMP OID and return parsed lines."""
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return []
    return res.stdout.splitlines()


def _parse_snmp_line(line):
    """Parse a snmpwalk line: 'OID = TYPE: value'."""
    eq_index = line.find("=")
    if eq_index == -1:
        return None, None
    oid_part = line[:eq_index].strip()
    value_part = line[eq_index + 1:].strip()
    colon_index = value_part.find(":")
    if colon_index == -1:
        return oid_part, value_part
    return oid_part, value_part[colon_index + 1:].strip()


def _build_section(ctx, community, host):
    """Build the section dict from SNMP data."""
    section = {}

    # Fetch media access devices
    media_access_oids = ["2.1", "3.1", "6.1"]  # ObjectType, Name, NeedsCleaning (per-instance)
    media_data = {}

    for oid_suffix in media_access_oids:
        lines = _walk_snmp(ctx, MEDIA_ACCESS_BASE + "." + oid_suffix, community, host)
        for line in lines:
            full_oid, value = _parse_snmp_line(line)
            if full_oid == None or value == None:
                continue
            # Extract instance number from OID: base.2.1.X
            dot_index = full_oid.rfind(".")
            if dot_index == -1:
                continue
            instance = full_oid[dot_index + 1:]
            if instance == "":
                continue
            if oid_suffix == "2.1":
                # type
                media_data.setdefault(instance, {})["type_raw"] = value
            elif oid_suffix == "3.1":
                # name
                media_data.setdefault(instance, {})["name"] = value
            elif oid_suffix == "6.1":
                # clean
                media_data.setdefault(instance, {})["clean_raw"] = value

    # Process media access devices
    for instance, data in media_data.items():
        name = data.get("name", "")
        device_key = _parse_device_name(name)
        if device_key == "":
            continue
        type_raw = data.get("type_raw", "0")
        clean_raw = data.get("clean_raw", "0")
        section[device_key] = {
            "type": TYPE_MAP.get(type_raw, "unknown"),
            "clean": CLEAN_MAP.get(clean_raw, "unknown"),
        }

    # Fetch controller info (OperationalStatus, Availability)
    ctrl_oids = ["3.1", "6.1", "4.1"]  # ElementName, Availability, OperationalStatus
    ctrl_data = {}

    for idx, oid_suffix in enumerate(["3.1", "6.1", "4.1"]):
        lines = _walk_snmp(ctx, CONTROLLER_BASE + "." + oid_suffix, community, host)
        for line in lines:
            full_oid, value = _parse_snmp_line(line)
            if full_oid == None or value == None:
                continue
            dot_index = full_oid.rfind(".")
            if dot_index == -1:
                continue
            instance = full_oid[dot_index + 1:]
            if instance == "":
                continue
            if oid_suffix == "3.1":
                # name
                ctrl_data.setdefault(instance, {})["name"] = value
            elif oid_suffix == "6.1":
                # availability
                ctrl_data.setdefault(instance, {})["availability"] = value
            elif oid_suffix == "4.1":
                # status
                ctrl_data.setdefault(instance, {})["status"] = value

    # Merge controller info into section
    for instance, data in ctrl_data.items():
        name = data.get("name", "")
        device_key = _parse_device_name(name)
        if device_key in section:
            section[device_key]["ctrl_avail"] = data.get("availability", "")
            section[device_key]["ctrl_status"] = data.get("status", "")

    return section


def _get_device_state(avail, status):
    """Map availability and status to state and message."""
    avail_str = AVAILABILITY_MAP.get(avail, "unknown")
    status_str = STATUS_MAP.get(status, "unknown")

    # CRIT if error, degraded
    if status_str == "error" or avail_str == "offline":
        return "CRIT", "Status: {}, Availability: {}".format(status_str, avail_str)
    if status_str == "degraded":
        return "WARN", "Status: {}, Availability: {}".format(status_str, avail_str)
    return "OK", "Status: {}, Availability: {}".format(status_str, avail_str)


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        section = _build_section(ctx, community, host)
        discovery = []
        for device_key in section:
            discovery.append({
                "item": device_key,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d devices" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    section = _build_section(ctx, community, host)

    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "device not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state = "OK"
    summary_parts = ["Type: " + data.get("type", "unknown")]
    summary_parts.append("Needs cleaning: " + data.get("clean", "unknown"))

    # If controller info available, use device state
    if data.get("ctrl_avail") != None and data.get("ctrl_status") != None:
        dev_state, dev_summary = _get_device_state(
            data.get("ctrl_avail", ""),
            data.get("ctrl_status", "")
        )
        if dev_state == "CRIT":
            state = "CRIT"
        elif dev_state == "WARN" and state != "CRIT":
            state = "WARN"
        summary_parts.append(dev_summary)

    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }