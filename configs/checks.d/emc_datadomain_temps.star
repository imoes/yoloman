def main(ctx, params):
    # SNMP OIDs for emc_datadomain_temps
    base_oid = ".1.3.6.1.4.1.19746.1.1.2.1.1.1"
    col_encid = base_oid + ".1"
    col_index = base_oid + ".2"
    col_descr = base_oid + ".4"
    col_reading = base_oid + ".5"
    col_status = base_oid + ".6"

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    version = params.get("version", "2c")

    # Status table from the Checkmk source
    status_table = {
        "0": (2, "Failed"),
        "1": (0, "OK"),
        "2": (2, "Not found"),
        "3": (1, "Overheat Warning"),
        "4": (2, "Overheat Critical"),
    }

    def format_name(descr, encid, index, new_format):
        if new_format:
            return "%s Enclosure %s" % (descr, encid)
        return "%s-%s" % (encid, index)

    def snmp_walk(oid):
        res = ctx.run(["snmpwalk", "-v" + version, "-c", community, "-Oqn",
                        host, oid], mutates=False)
        if res.rc != 0 or not res.stdout:
            return []
        rows = []
        for line in res.stdout.splitlines():
            space_idx = line.find(" ")
            if space_idx < 0:
                continue
            oid_part = line[:space_idx]
            value = line[space_idx + 1:]
            rows.append((oid_part, value))
        return rows

    def snmp_get(oid):
        res = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv",
                        host, oid], mutates=False)
        if res.rc != 0 or not res.stdout:
            return ""
        val = res.stdout.strip()
        if val.startswith('"') and val.endswith('"') and len(val) >= 2:
            val = val[1:-1]
        return val

    # Verify this is an EMC Data Domain system
    sys_descr = snmp_get(".1.3.6.1.2.1.1.1.0")
    if not sys_descr.startswith("Data Domain OS"):
        return {"changed": False, "msg": "not an EMC Data Domain system",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Discovery mode
    if params.get("_discover"):
        # Walk all columns and group by index
        encid_rows = snmp_walk(col_encid)
        index_rows = snmp_walk(col_index)
        descr_rows = snmp_walk(col_descr)
        reading_rows = snmp_walk(col_reading)
        status_rows = snmp_walk(col_status)

        def index_of(oid):
            if oid.startswith(col_encid + "."):
                return oid[len(col_encid) + 1:]
            return None

        # Build index -> values map
        indices = {}
        for oid, val in encid_rows:
            idx = oid[len(col_encid) + 1:]
            if idx not in indices:
                indices[idx] = {}
            indices[idx]["encid"] = val
        for oid, val in index_rows:
            idx = oid[len(col_index) + 1:]
            if idx not in indices:
                indices[idx] = {}
            indices[idx]["index"] = val
        for oid, val in descr_rows:
            idx = oid[len(col_descr) + 1:]
            if idx not in indices:
                indices[idx] = {}
            indices[idx]["descr"] = val
        for oid, val in reading_rows:
            idx = oid[len(col_reading) + 1:]
            if idx not in indices:
                indices[idx] = {}
            indices[idx]["reading"] = val
        for oid, val in status_rows:
            idx = oid[len(col_status) + 1:]
            if idx not in indices:
                indices[idx] = {}
            indices[idx]["status"] = val

        discovery = []
        for idx, vals in sorted(indices.items()):
            status = vals.get("status", "2")
            if status == "2":
                continue
            encid = vals.get("encid", "")
            index = vals.get("index", "")
            descr = vals.get("descr", "")
            name = format_name(descr, encid, index, True)
            discovery.append({
                "item": name,
                "params": {"levels": (60, 70)},
                "metrics": ["temperature"],
            })

        return {"changed": False,
                "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode for a specific item
    item = params.get("item", "")

    # Re-walk to get current state (discovery and check both need live data)
    encid_rows = snmp_walk(col_encid)
    index_rows = snmp_walk(col_index)
    descr_rows = snmp_walk(col_descr)
    reading_rows = snmp_walk(col_reading)
    status_rows = snmp_walk(col_status)

    indices = {}
    for oid, val in encid_rows:
        idx = oid[len(col_encid) + 1:]
        if idx not in indices:
            indices[idx] = {}
        indices[idx]["encid"] = val
    for oid, val in index_rows:
        idx = oid[len(col_index) + 1:]
        if idx not in indices:
            indices[idx] = {}
        indices[idx]["index"] = val
    for oid, val in descr_rows:
        idx = oid[len(col_descr) + 1:]
        if idx not in indices:
            indices[idx] = {}
        indices[idx]["descr"] = val
    for oid, val in reading_rows:
        idx = oid[len(col_reading) + 1:]
        if idx not in indices:
            indices[idx] = {}
        indices[idx]["reading"] = val
    for oid, val in status_rows:
        idx = oid[len(col_status) + 1:]
        if idx not in indices:
            indices[idx] = {}
        indices[idx]["status"] = val

    # Determine if new format (description in item name)
    use_new_format = "Enclosure" in item

    found = False
    for idx, vals in sorted(indices.items()):
        status = vals.get("status", "2")
        if status == "2":
            continue
        encid = vals.get("encid", "")
        index = vals.get("index", "")
        descr = vals.get("descr", "")
        name = format_name(descr, encid, index, use_new_format)
        if name == item:
            found = True
            reading_str = vals.get("reading", "")
            if not reading_str or reading_str == "No Such Object":
                return {"changed": False,
                        "msg": "no reading for " + item,
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

            # Parse reading - could be quoted string or numeric
            reading_val = reading_str
            if reading_val.startswith('"') and reading_val.endswith('"'):
                reading_val = reading_val[1:-1]
            try_val = float(reading_val)
            
            warn_level = params.get("warn", 60)
            crit_level = params.get("crit", 70)
            levels = params.get("levels", None)
            if levels != None and len(levels) >= 2:
                warn_level = levels[0]
                crit_level = levels[1]

            dev_status, state_name = (0, "OK")
            status_entry = status_table.get(status, (0, "Unknown"))
            dev_status = status_entry[0]
            dev_status_name = status_entry[1]

            metric_state = "OK"
            if try_val >= crit_level:
                metric_state = "CRIT"
            elif try_val >= warn_level:
                metric_state = "WARN"

            # Device status takes precedence: 2 = CRIT, 1 = WARN, 0 = OK
            final_state = "OK"
            if dev_status == 2:
                final_state = "CRIT"
            elif dev_status == 1:
                final_state = "WARN"
            elif dev_status == 0:
                # Use metric-based state if device status is OK
                final_state = metric_state

            state_map = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
            metric_state_num = state_map.get(final_state, 3)

            details = "Temperature reading: %s, Device status: %s" % (reading_str, dev_status_name)

            return {"changed": False,
                    "msg": "Enclosure %s temperature: %s C (%s)" % (encid, reading_str, dev_status_name),
                    "data": {"state": final_state,
                             "metrics": {"temperature": try_val},
                             "details": details}}

    if not found:
        return {"changed": False,
                "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}