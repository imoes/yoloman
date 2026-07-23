def main(ctx, params):
    # SNMP base configuration
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Helper to parse SNMP line: "oid = TYPE: value"
    def parse_snmp_line(line):
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            return None, None
        oid = parts[0].strip()
        value = parts[1].strip()
        # Remove type prefix if present (e.g., "STRING:", "INTEGER:", etc.)
        if ":" in value:
            value = value.split(":", 1)[1].strip().strip('"')
        return oid, value

    # Helper to build oid list
    def build_oid(base, suffix):
        return base + "." + suffix

    # Fetch all required SNMP trees in one go (snmpwalk)
    # Tree 1: .1.3.6.1.4.1.2.6.210.1 -> info (1,3,4)
    # Tree 2: .1.3.6.1.4.1.2.6.210.2 -> status (1)
    # Tree 3: .1.3.6.1.4.1.2.6.210.3.1.1 -> libraries (1,2,10,11,22,23,24)
    # Tree 4: .1.3.6.1.4.1.2.6.210.3.2.1 -> drives (1,10,15,16,17,18)
    base_info = ".1.3.6.1.4.1.2.6.210.1"
    base_status = ".1.3.6.1.4.1.2.6.210.2"
    base_library = ".1.3.6.1.4.1.2.6.210.3.1.1"
    base_drive = ".1.3.6.1.4.1.2.6.210.3.2.1"

    # Build full OIDs
    info_oids = [
        build_oid(base_info, "1"),   # product
        build_oid(base_info, "3"),   # vendor
        build_oid(base_info, "4"),   # version
    ]
    status_oid = build_oid(base_status, "1")
    library_oids = [
        build_oid(base_library, "1"),   # entry
        build_oid(base_library, "2"),   # status
        build_oid(base_library, "10"),  # serial
        build_oid(base_library, "11"),  # drive_count
        build_oid(base_library, "22"),  # fault
        build_oid(base_library, "23"),  # severity
        build_oid(base_library, "24"),  # descr
    ]
    drive_oids = [
        build_oid(base_drive, "1"),   # entry
        build_oid(base_drive, "10"),  # serial
        build_oid(base_drive, "15"),  # write_warn
        build_oid(base_drive, "16"),  # write_err
        build_oid(base_drive, "17"),  # read_warn
        build_oid(base_drive, "18"),  # read_err
    ]

    # Fetch all OIDs at once (snmpwalk)
    cmd = ["snmpwalk", "-v2c", "-c", community, "-On", host] + \
          sorted(set(info_oids + [status_oid] + library_oids + drive_oids))
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse flat output into structured data
    # We'll use a dict: {oid_base: {"1": val, "2": val, ...}}
    raw_data = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        oid, value = parse_snmp_line(line)
        if oid == None or oid == "":
            continue
        # Normalize to just the tail (numeric suffix after base)
        # We'll match by checking if the oid starts with any base
        # But simpler: group by the numeric suffix part
        # Extract the last numeric segment after the last dot
        parts = oid.split(".")
        suffix = ".".join(parts[-1:])
        # Store in nested dict for easier lookup
        # For simplicity, we'll collect everything in one pass and match bases later
        # Better: store full oid -> value, then group by base
        raw_data[oid] = value

    # Helper: get value for a given base OID + suffix
    def get_value(base, suffix):
        full = base + "." + suffix
        return raw_data.get(full, "")

    # Parse section: info, status, libraries, drives
    info_raw = [get_value(base_info, "1"), get_value(base_info, "3"), get_value(base_info, "4")]
    # Filter empty strings to avoid parsing errors
    if not any(info_raw):
        # No data found — device likely doesn’t support this MIB
        return {
            "changed": False,
            "msg": "No IBM Storage TS data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Map status names
    status_name_map = {
        "1": "other",
        "2": "unknown",
        "3": "Ok",
        "4": "non-critical",
        "5": "critical",
        "6": "non-Recoverable",
    }
    status_nagios_map = {
        "1": "WARN",
        "2": "WARN",
        "3": "OK",
        "4": "WARN",
        "5": "CRIT",
        "6": "CRIT",
    }
    fault_map = {
        "0": "OK",  # no fault (undocumented)
        "1": "OK",  # informational
        "2": "WARN",  # minor
        "3": "CRIT",  # major
        "4": "CRIT",  # critical
    }

    # Build libraries and drives lists
    libraries = []
    # Find library entries by scanning .1 (library entry index)
    # We need to collect library entries by their index
    # Iterate possible indices until no more data
    idx = 1
    while True:
        entry = get_value(base_library, str(idx) + ".1")
        if not entry:
            break
        # Extract all fields for this library index
        # Note: SNMP tree has fixed oids per row: 1=entry, 2=status, 10=serial, 11=drive_count, 22=fault, 23=severity, 24=descr
        # But in snmpwalk, we have flat oid -> value, so reconstruct
        # Instead, we scan for all library oids starting with base and containing ".idx."
        status_val = get_value(base_library, str(idx) + ".2")
        serial_val = get_value(base_library, str(idx) + ".10")
        drive_count_val = get_value(base_library, str(idx) + ".11")
        fault_val = get_value(base_library, str(idx) + ".22")
        severity_val = get_value(base_library, str(idx) + ".23")
        descr_val = get_value(base_library, str(idx) + ".24")

        libraries.append({
            "entry": entry,
            "status": status_val if status_val else "2",
            "serial": serial_val if serial_val else "",
            "drive_count": drive_count_val if drive_count_val else "",
            "fault": fault_val if fault_val else "0",
            "severity": severity_val if severity_val else "0",
            "descr": descr_val if descr_val else "",
        })
        idx += 1

    # Build drives list similarly
    drives = []
    idx = 1
    while True:
        entry = get_value(base_drive, str(idx) + ".1")
        if not entry:
            break
        serial_val = get_value(base_drive, str(idx) + ".10")
        write_warn = get_value(base_drive, str(idx) + ".15")
        write_err = get_value(base_drive, str(idx) + ".16")
        read_warn = get_value(base_drive, str(idx) + ".17")
        read_err = get_value(base_drive, str(idx) + ".18")

        drives.append({
            "entry": entry,
            "serial": serial_val if serial_val else "",
            "write_warn": write_warn if write_warn else "",
            "write_err": write_err if write_err else "",
            "read_warn": read_warn if read_warn else "",
            "read_err": read_err if read_err else "",
        })
        idx += 1

    # If discovery mode, return services
    if params.get("_discover"):
        out = [{"item": "", "params": {}, "metrics": []}]  # single-service check
        if libraries:
            out.append({"item": "", "params": {}, "metrics": ["library_count"]})
        if drives:
            out.append({"item": "", "params": {}, "metrics": ["drive_count"]})
        # But per the source, each check plugin yields one service only
        # Our check_plugin_ibm_storage_ts yields one "Info" service (item "")
        return {
            "changed": False,
            "msg": "discovered services",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Normal check mode: item is "" (only one item per the source)
    item = params.get("item", "")

    # For now, we only implement the main Info check (check_plugin_ibm_storage_ts)
    # as requested by the short description "Info"
    vendor = info_raw[1] if info_raw[1] else "Unknown"
    product = info_raw[0] if info_raw[0] else "Unknown"
    version = info_raw[2] if info_raw[2] else "Unknown"
    return {
        "changed": False,
        "msg": "%s %s, Version %s" % (vendor, product, version),
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }