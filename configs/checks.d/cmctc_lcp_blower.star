# cmctc_lcp_blower starlark check module
# Translates Checkmk check cmk.plugins.rittal.cmctc_lcp_blower
# Reads SNMP data from CMC TC LCP device blowers

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    warn_val, crit_val = params.get("levels", (None, None))

    # SNMP base OIDs for the four trees: cmcTcUnit1OutputTable..4
    trees = ["3", "4", "5", "6"]
    # Mapping typeid -> (prefix, type_)
    sensor_map = {
        "40": ("1", "blower"),
        "41": ("2", "blower"),
        "42": ("3", "blower"),
        "43": ("4", "blower"),
        "44": ("5", "blower"),
        "45": ("6", "blower"),
        "46": ("7", "blower"),
        "47": ("8", "blower"),
    }

    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        items = []
        for tree in trees:
            base_oid = ".1.3.6.1.4.1.2606.4.2." + tree + ".5.2.1"
            # oid list: index(1), typeid(2), status(4), reading(5), high(6), low(7), warn(8), description(2)
            oids = [
                base_oid + ".1",  # index
                base_oid + ".2",  # typeid
                base_oid + ".4",  # status
                base_oid + ".5",  # reading
                base_oid + ".6",  # high
                base_oid + ".7",  # low
                base_oid + ".8",  # warn
                base_oid + ".7.2.1.2",  # description (per tree index)
            ]
            rows = {}
            for idx, oid in enumerate(oids):
                res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
                for line in res.stdout.splitlines():
                    if not line.strip():
                        continue
                    parts = line.strip().split(" = ", 2)
                    if len(parts) < 2:
                        continue
                    oid_part, val_part = parts
                    last_dot = oid_part.rfind(".")
                    if last_dot == -1:
                        continue
                    idx_val_str = oid_part[last_dot + 1:]
                    if not idx_val_str.isdigit():
                        continue
                    idx_val = int(idx_val_str)
                    val = val_part.strip()
                    if ":" in val:
                        val = val.split(":", 1)[1].strip()
                        if val.startswith('"') and val.endswith('"'):
                            val = val[1:-1]

                    if idx_val not in rows:
                        rows[idx_val] = {}
                    rows[idx_val][["index", "typeid", "status", "reading", "high", "low", "warn", "description"][idx]] = val

            for idx_val, row in rows.items():
                typeid = row.get("typeid", "")
                if typeid not in sensor_map:
                    continue
                sensor_spec = sensor_map[typeid]
                item_prefix = sensor_spec[0]
                if item_prefix:
                    item_name = item_prefix + " - " + tree + "." + str(idx_val)
                else:
                    item_name = tree + "." + str(idx_val)

                items.append({
                    "item": item_name,
                    "params": {"levels": (0, 0)},
                    "metrics": ["blower"]
                })

        return {
            "changed": False,
            "msg": "discovered %d blowers" % len(items),
            "data": {"discovery": items}
        }

    # ===== CHECK MODE =====
    # Gather data for the requested item
    found = False
    status = ""
    reading = 0.0
    high_val = 0.0
    low_val = 0.0
    warn_from_snmp = 0.0
    description = ""

    for tree in trees:
        base_oid = ".1.3.6.1.4.1.2606.4.2." + tree + ".5.2.1"
        oids = [
            base_oid + ".1",  # index
            base_oid + ".2",  # typeid
            base_oid + ".4",  # status
            base_oid + ".5",  # reading
            base_oid + ".6",  # high
            base_oid + ".7",  # low
            base_oid + ".8",  # warn
            base_oid + ".7.2.1.2",  # description
        ]
        rows = {}
        for idx, oid in enumerate(oids):
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
            for line in res.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.strip().split(" = ", 2)
                if len(parts) < 2:
                    continue
                oid_part, val_part = parts
                last_dot = oid_part.rfind(".")
                if last_dot == -1:
                    continue
                idx_val_str = oid_part[last_dot + 1:]
                if not idx_val_str.isdigit():
                    continue
                idx_val = int(idx_val_str)
                val = val_part.strip()
                if ":" in val:
                    val = val.split(":", 1)[1].strip()
                    if val.startswith('"') and val.endswith('"'):
                        val = val[1:-1]

                if idx_val not in rows:
                    rows[idx_val] = {}
                rows[idx_val][["index", "typeid", "status", "reading", "high", "low", "warn", "description"][idx]] = val

        for idx_val, row in rows.items():
            typeid = row.get("typeid", "")
            if typeid not in sensor_map:
                continue
            sensor_spec = sensor_map[typeid]
            item_prefix = sensor_spec[0]
            if item_prefix:
                row_item = item_prefix + " - " + tree + "." + str(idx_val)
            else:
                row_item = tree + "." + str(idx_val)

            if row_item == item:
                found = True
                status = row.get("status", "0")
                reading_str = row.get("reading", "0")
                if reading_str.isdigit():
                    reading = float(reading_str)
                else:
                    reading = 0.0
                high_str = row.get("high", "0")
                if high_str.isdigit():
                    high_val = float(high_str)
                else:
                    high_val = 0.0
                low_str = row.get("low", "0")
                if low_str.isdigit():
                    low_val = float(low_str)
                else:
                    low_val = 0.0
                warn_str = row.get("warn", "0")
                if warn_str.isdigit():
                    warn_from_snmp = float(warn_str)
                else:
                    warn_from_snmp = 0.0
                description = row.get("description", "")
                break
        if found:
            break

    if not found:
        return {
            "changed": False,
            "msg": "blower not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Status mapping: 1=notAvail(3), 2=lost(2), 3=changed(1), 4=ok(0),
    #                 5=off(2), 6=on(0), 7=warning(1), 8=too low(2), 9=too high(2), 10=error(2)
    state_map = {
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

    def_state = 3
    def_info = "unknown"
    if status in state_map:
        def_state, def_info = state_map[status]

    infotext = ""
    if description:
        infotext += "[" + description + "] "

    # Unit for blower: RPM
    unit = " RPM"
    infotext += str(int(reading)) + unit

    # Determine state based on device levels and user params
    state = def_state
    extra_info = ""
    if def_state == 0:
        extra_info = def_info
    elif def_info != "":
        extra_info = def_info

    # User levels override device levels if provided
    if warn_val != None and crit_val != None:
        warn_val_num = float(warn_val)
        crit_val_num = float(crit_val)
        if reading >= crit_val_num:
            state = 2
        elif reading >= warn_val_num:
            state = 1
        if state > 0:
            extra_info += " (warn/crit at " + str(int(warn_val_num)) + "/" + str(int(crit_val_num)) + unit + ")"
    else:
        # No user levels: use device levels if present
        if low_val < high_val and (low_val > 0 or high_val > 0):
            if reading >= high_val or reading <= low_val:
                state = 2
                extra_info += " (device lower/upper crit at " + str(int(low_val)) + "/" + str(int(high_val)) + unit + ")"

    # Metric name for blower: "blower"
    metrics = {"blower": reading}

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": "OK" if state == 0 else ("WARN" if state == 1 else ("CRIT" if state == 2 else "UNKNOWN")),
            "metrics": metrics,
            "details": extra_info
        }
    }