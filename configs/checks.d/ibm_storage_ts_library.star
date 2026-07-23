def main(ctx, params):
    # Discovery mode: enumerate library entries
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.6.210.3.1.1"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }

        # Parse library entries from SNMP output
        # OID suffixes: 1=entry, 2=status, 10=serial, 11=drive_count, 22=fault, 23=severity, 24=descr
        libraries = []
        lines = res.stdout.splitlines()
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_val = parts[0].strip()
            val = parts[1].strip()
            if not val.startswith("STRING:"):
                continue
            val = val[7:].strip().strip('"')

            # Extract entry name from OID: .1.3.6.1.4.1.2.6.210.3.1.1.1.<entry_id>
            # We need to group by entry_id to collect all fields
            # We'll collect in a dict keyed by entry name
            pass  # Will restructure below

        # Better approach: walk each OID separately and align
        # Walk entry (field 1)
        res_entry = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.6.210.3.1.1.1"
        ], mutates=False)
        if res_entry.rc != 0:
            res_entry.stdout = ""

        # Walk status (field 2)
        res_status = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.6.210.3.1.1.2"
        ], mutates=False)
        if res_status.rc != 0:
            res_status.stdout = ""

        # Walk serial (field 10)
        res_serial = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.6.210.3.1.1.10"
        ], mutates=False)
        if res_serial.rc != 0:
            res_serial.stdout = ""

        # Walk drive_count (field 11)
        res_drive_count = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.6.210.3.1.1.11"
        ], mutates=False)
        if res_drive_count.rc != 0:
            res_drive_count.stdout = ""

        # Walk fault (field 22)
        res_fault = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.6.210.3.1.1.22"
        ], mutates=False)
        if res_fault.rc != 0:
            res_fault.stdout = ""

        # Walk severity (field 23)
        res_severity = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.6.210.3.1.1.23"
        ], mutates=False)
        if res_severity.rc != 0:
            res_severity.stdout = ""

        # Walk descr (field 24)
        res_descr = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.6.210.3.1.1.24"
        ], mutates=False)
        if res_descr.rc != 0:
            res_descr.stdout = ""

        # Parse values
        def parse_snmp_values(res):
            result = {}
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) < 2:
                    continue
                oid_path = parts[0].strip()
                val = parts[1].strip()
                if val.startswith("STRING:"):
                    val = val[7:].strip().strip('"')
                elif val.startswith("INTEGER:"):
                    val = val[8:].strip()
                elif val.startswith("Counter"):
                    val = val.split(":")[1].strip()
                else:
                    val = val.split(":")[1].strip() if ":" in val else val
                # Extract last component of OID as key (the index)
                idx = oid_path.rsplit(".", 1)[-1]
                result[idx] = val
            return result

        entries = parse_snmp_values(res_entry)
        statuses = parse_snmp_values(res_status)
        serials = parse_snmp_values(res_serial)
        drive_counts = parse_snmp_values(res_drive_count)
        faults = parse_snmp_values(res_fault)
        severities = parse_snmp_values(res_severity)
        descrs = parse_snmp_values(res_descr)

        # Collect all libraries
        library_list = []
        for idx in entries:
            status_val = statuses.get(idx, "2")
            fault_val = faults.get(idx, "0")
            severity_val = severities.get(idx, "1")
            library = {
                "entry": entries[idx],
                "status": status_val,
                "serial": serials.get(idx, ""),
                "drive_count": drive_counts.get(idx, "0"),
                "fault": fault_val,
                "severity": severity_val,
                "descr": descrs.get(idx, "")
            }
            library_list.append(library)

        out = []
        for lib in library_list:
            out.append({
                "item": lib["entry"],
                "params": {},
                "metrics": []
            })

        return {
            "changed": False,
            "msg": "discovered %d libraries" % len(out),
            "data": {"discovery": out}
        }

    # Check mode
    item = params.get("item", "")

    # Run all necessary SNMP walks
    res_entry = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2.6.210.3.1.1.1"
    ], mutates=False)
    res_status = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2.6.210.3.1.1.2"
    ], mutates=False)
    res_serial = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2.6.210.3.1.1.10"
    ], mutates=False)
    res_drive_count = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2.6.210.3.1.1.11"
    ], mutates=False)
    res_fault = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2.6.210.3.1.1.22"
    ], mutates=False)
    res_severity = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2.6.210.3.1.1.23"
    ], mutates=False)
    res_descr = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2.6.210.3.1.1.24"
    ], mutates=False)

    if res_entry.rc != 0 or res_status.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP failure",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    def parse_snmp_values(res):
        result = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_path = parts[0].strip()
            val = parts[1].strip()
            if val.startswith("STRING:"):
                val = val[7:].strip().strip('"')
            elif val.startswith("INTEGER:"):
                val = val[8:].strip()
            else:
                # For other types, try to extract the value after colon
                if ":" in val:
                    val = val.split(":", 1)[1].strip()
            idx = oid_path.rsplit(".", 1)[-1]
            result[idx] = val
        return result

    entries = parse_snmp_values(res_entry)
    statuses = parse_snmp_values(res_status)
    serials = parse_snmp_values(res_serial)
    drive_counts = parse_snmp_values(res_drive_count)
    faults = parse_snmp_values(res_fault)
    severities = parse_snmp_values(res_severity)
    descrs = parse_snmp_values(res_descr)

    # Find the requested library item
    for idx in entries:
        if entries[idx] == item:
            status_val = statuses.get(idx, "2")
            serial_val = serials.get(idx, "")
            drive_count_val = drive_counts.get(idx, "0")
            fault_val = faults.get(idx, "0")
            severity_val = severities.get(idx, "1")
            descr_val = descrs.get(idx, "")

            # Map status to State
            status_map = {
                "1": "WARN", "2": "WARN", "3": "OK", "4": "WARN", "5": "CRIT", "6": "CRIT"
            }
            status_name_map = {
                "1": "other", "2": "unknown", "3": "Ok", "4": "non-critical",
                "5": "critical", "6": "non-Recoverable"
            }

            status_name = status_name_map.get(status_val, "unknown")
            status_state = status_map.get(status_val, "WARN")

            # Map fault/severity
            fault_map = {
                "0": "OK", "1": "OK", "2": "WARN", "3": "CRIT", "4": "CRIT"
            }
            fault_state = fault_map.get(fault_val, "OK")

            # Determine worst state
            state_order = {"OK": 0, "WARN": 1, "CRIT": 2}
            worst_state = "OK"
            if state_order.get(status_state, 0) > state_order.get(worst_state, 0):
                worst_state = status_state
            if state_order.get(fault_state, 0) > state_order.get(worst_state, 0):
                worst_state = fault_state

            # Build summary message
            infotext = "Device %s, Status: %s, Drives: %s" % (
                serial_val, status_name, drive_count_val
            )
            if fault_val != "0":
                infotext += ", Fault: %s (%s)" % (descr_val, fault_val)

            return {
                "changed": False,
                "msg": infotext,
                "data": {"state": worst_state, "metrics": {}, "details": ""}
            }

    # Library item not found
    return {
        "changed": False,
        "msg": "library not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }