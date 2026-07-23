def main(ctx, params):
    # SNMP base and OIDs for ibm_storage_ts_drive section
    BASE = ".1.3.6.1.4.1.2.6.210.3.2.1"
    OIDS = ["1", "10", "15", "16", "17", "18"]  # entry, serial, write_warn, write_err, read_warn, read_err

    if params.get("_discover"):
        # Discover drives by walking the drive table
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            BASE
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}

        # Parse snmpwalk output: lines like "<oid>.<index> = STRING: <value>"
        drives = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0]
            value_part = parts[1]
            # Extract index from oid (e.g., ".1.3.6.1.4.1.2.6.210.3.2.1.1.1" -> last segment)
            idx = oid_part.rfind(".")
            if idx == -1:
                continue
            idx_str = oid_part[idx+1:]
            if not idx_str.isdigit():
                continue

            # Value parsing: strip quotes from STRING types
            val = value_part
            if val.startswith("STRING: "):
                val = val[len("STRING: "):].strip('"')
            elif val.startswith("INTEGER: "):
                val = val[len("INTEGER: "):]
            elif val.startswith("Gauge32: "):
                val = val[len("Gauge32: "):]
            elif val.startswith("Counter32: "):
                val = val[len("Counter32: "):]

            # We only need the first OID (entry) to identify a drive instance
            # The OID index corresponds to drive entry index
            if oid_part.endswith(".1." + idx_str):  # OID ending with .1.<index> => entry
                drives.append(idx_str)

        out = [{"item": drive, "params": {}, "metrics": 
                ["write_warn", "write_err", "read_warn", "read_err"]} for drive in drives]
        return {"changed": False, "msg": "discovered %d drives" % len(drives),
                "data": {"discovery": out}}

    # Check mode for a specific drive
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch all drive table columns via snmpget
    entries = []
    serials = []
    write_warns = []
    write_errs = []
    read_warns = []
    read_errs = []

    # Get OID indices for this specific drive's columns (item is index)
    base_oid = BASE + ".%s" % item
    oids = [base_oid + "." + str(i) for i in range(1, 7)]

    for oid in oids:
        res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), oid
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP get failed for drive %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        # Parse: "<oid> = STRING: <value>" or similar
        line = res.stdout.strip()
        parts = line.split(" = ")
        if len(parts) != 2:
            return {"changed": False, "msg": "invalid SNMP output for drive %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        val = parts[1]
        if val.startswith("STRING: "):
            val = val[len("STRING: "):].strip('"')
        elif val.startswith("INTEGER: "):
            val = val[len("INTEGER: "):]
        elif val.startswith("Gauge32: "):
            val = val[len("Gauge32: "):]
        elif val.startswith("Counter32: "):
            val = val[len("Counter32: "):]
        entries.append(val)

    if len(entries) != 6:
        return {"changed": False, "msg": "missing drive data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Map fields
    entry = entries[0]
    serial = entries[1]
    write_warn = entries[2]
    write_err = entries[3]
    read_warn = entries[4]
    read_err = entries[5]

    # Check drive entry matches requested item
    if entry != item:
        return {"changed": False, "msg": "drive item mismatch",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    summary_parts = []
    metrics = {}

    summary_parts.append("S/N: " + serial)

    # Check counters (non-zero triggers status)
    for name, counter, warn_state, crit_state in [
        ("write_warn", write_warn, "WARN", "CRIT"),
        ("write_err", write_err, "CRIT", "CRIT"),
        ("read_warn", read_warn, "WARN", "CRIT"),
        ("read_err", read_err, "CRIT", "CRIT"),
    ]:
        if counter == "":
            return {"changed": False, "msg": "got empty string for " + name,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        # Convert to number if possible
        num = int(counter) if counter.isdigit() else -1
        metrics[name] = num
        if counter != "0":
            if name in ("write_err", "read_err"):
                state = "CRIT"
            elif name in ("write_warn", "read_warn"):
                if state != "CRIT":
                    state = "WARN"
            summary_parts.append("%s: %s" % (name.replace("_", " "), counter))

    return {"changed": False, "msg": ", ".join(summary_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}