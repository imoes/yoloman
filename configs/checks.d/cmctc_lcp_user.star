# Sensor type mapping from typeid to (subitem, type_) — matches _CMCTC_LCP_SENSORS in source
_SENSOR_TYPES = {
    "13": ("normally open", "user"),
    "14": ("normally closed", "user"),
}

# SNMP base OIDs per tree index (trees 3-6 per _TREES in source)
_TREE_OIDS = {
    3: ".1.3.6.1.4.1.2606.4.2.3",
    4: ".1.3.6.1.4.1.2606.4.2.4",
    5: ".1.3.6.1.4.1.2606.4.2.5",
    6: ".1.3.6.1.4.1.2606.4.2.6",
}

# Status mapping: status code -> (state_idx, extra_info_text) — state 0=OK,1=WARN,2=CRIT,3=UNKNOWN
_STATE_MAP = {
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


def _parse_snmp_line(line):
    # Parse snmpwalk output line: "<oid> = <type>: <value>"
    if not line.strip():
        return None
    idx_eq = line.find("=")
    if idx_eq == -1:
        return None
    val_part = line[idx_eq + 1:].strip()
    # Split type and value (e.g. "INTEGER: 4" or "STRING: test")
    idx_colon = val_part.find(":")
    if idx_colon == -1:
        return None
    value_str = val_part[idx_colon + 1:].strip()
    # Strip quotes from strings
    if value_str.startswith('"') and value_str.endswith('"'):
        value_str = value_str[1:-1]
    return value_str


def _walk_tree(ctx, tree_oid, base_index):
    # Walk a tree and return list of rows (6 columns: index, typeid, status, reading, high, low, warn, description)
    res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", tree_oid], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    # Columns to collect (OIDs relative to base, but snmpwalk yields full OIDs; we rely on order)
    # The source OIDs are: 5.2.1.1 (index), 5.2.1.2 (typeid), 5.2.1.4 (status),
    #                     5.2.1.5 (reading), 5.2.1.6 (high), 5.2.1.7 (low), 5.2.1.8 (warn), 7.2.1.2 (description)
    # For simplicity, we walk each OID separately in order and group by index
    base_oid = tree_oid + ".5.2.1."
    idx_oid = base_oid + "1"
    typeid_oid = base_oid + "2"
    status_oid = base_oid + "4"
    reading_oid = base_oid + "5"
    high_oid = base_oid + "6"
    low_oid = base_oid + "7"
    warn_oid = base_oid + "8"
    desc_oid = tree_oid + ".7.2.1.2"

    def walk_oid(oid):
        r = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", oid], mutates=False)
        if r.rc != 0:
            return {}
        out = {}
        for line in r.stdout.splitlines():
            if not line.strip():
                continue
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            val_part = line[eq_idx + 1:].strip()
            colon_idx = val_part.find(":")
            if colon_idx == -1:
                continue
            val = val_part[colon_idx + 1:].strip()
            # Strip quotes
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            # Extract last number from OID as index (e.g. ".1.3.6.1.4.1.2606.4.2.3.5.2.1.1.1.2 -> index 1")
            dot_parts = line[:eq_idx].strip().split(".")
            if len(dot_parts) > 0:
                idx_str = dot_parts[-1]
                if idx_str.isdigit():
                    out[int(idx_str)] = val
        return out

    idxs = walk_oid(idx_oid)
    typeids = walk_oid(typeid_oid)
    statuses = walk_oid(status_oid)
    readings = walk_oid(reading_oid)
    highs = walk_oid(high_oid)
    lows = walk_oid(low_oid)
    warns = walk_oid(warn_oid)
    descs = walk_oid(desc_oid)

    # Union of indices
    all_indices = set(idxs.keys()) | set(typeids.keys()) | set(statuses.keys()) | set(readings.keys()) | set(highs.keys()) | set(lows.keys()) | set(warns.keys()) | set(descs.keys())
    for i in sorted(all_indices):
        idx_str = str(i)
        typeid = typeids.get(i, "")
        status = statuses.get(i, "")
        reading = readings.get(i, "")
        high = highs.get(i, "")
        low = lows.get(i, "")
        warn = warns.get(i, "")
        desc = descs.get(i, "")
        rows.append((idx_str, typeid, status, reading, high, low, warn, desc))
    return rows


def main(ctx, params):
    if params.get("_discover"):
        discovered = []
        # Walk trees 3 to 6
        for tree_num in [3, 4, 5, 6]:
            tree_oid = _TREE_OIDS.get(tree_num)
            if not tree_oid:
                continue
            rows = _walk_tree(ctx, tree_oid, tree_num)
            for idx_str, typeid, status, reading, high, low, warn, desc in rows:
                sensor_spec = _SENSOR_TYPES.get(typeid)
                if not sensor_spec:
                    continue
                subitem, sensor_type = sensor_spec
                item = subitem + " - " + str(tree_num) + "." + idx_str if subitem else str(tree_num) + "." + idx_str
                # Suggested default: no levels (check uses empty params by default)
                discovered.append({
                    "item": item,
                    "params": {},
                    "metrics": ["user"],
                })
        return {
            "changed": False,
            "msg": "discovered %d user sensors" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "")
    # Gather data from all trees, then filter by item
    for tree_num in [3, 4, 5, 6]:
        tree_oid = _TREE_OIDS.get(tree_num)
        if not tree_oid:
            continue
        rows = _walk_tree(ctx, tree_oid, tree_num)
        for idx_str, typeid, status, reading, high, low, warn, desc in rows:
            sensor_spec = _SENSOR_TYPES.get(typeid)
            if not sensor_spec:
                continue
            subitem, sensor_type = sensor_spec
            candidate_item = subitem + " - " + str(tree_num) + "." + idx_str if subitem else str(tree_num) + "." + idx_str
            if candidate_item != item:
                continue
            # Found matching item
            status_int = int(status) if status.isdigit() else 0
            reading_val = float(reading) if reading and reading.lstrip("-").replace(".", "", 1).isdigit() else 0.0

            # Status to state
            state_info = _STATE_MAP.get(status, (3, "unknown"))
            base_state_idx, extra_text = state_info
            infotext = ""
            if desc:
                infotext += "[%s] " % desc
            unit = " "  # user sensor has no unit
            infotext += str(int(reading_val)) + unit
            state = "OK" if base_state_idx == 0 else ("WARN" if base_state_idx == 1 else ("CRIT" if base_state_idx == 2 else "UNKNOWN"))

            # Apply levels if provided (source uses params = warn/crit tuple; default empty means no levels)
            extra_state = 0
            params_warn = params.get("warn")
            params_crit = params.get("crit")
            if params_warn != None and params_crit != None:
                warn_val = float(params_warn)
                crit_val = float(params_crit)
                if reading_val >= crit_val:
                    extra_state = 2
                elif reading_val >= warn_val:
                    extra_state = 1
                if extra_state:
                    extra_text += " (warn/crit at %d/%d%s)" % (int(warn_val), int(crit_val), unit)
            elif reading_val != None:  # fallback to device levels (source uses has_levels logic, but for user sensor levels are typically zeros)
                # Device levels (low, warn, high) — for user sensor, skip unless non-zero
                high_val = float(high) if high and high.lstrip("-").replace(".", "", 1).isdigit() else 0.0
                low_val = float(low) if low and low.lstrip("-").replace(".", "", 1).isdigit() else 0.0
                warn_val_device = float(warn) if warn and warn.lstrip("-").replace(".", "", 1).isdigit() else 0.0
                # Only apply if non-trivial levels exist
                if (low_val != 0.0 or high_val != 0.0 or warn_val_device != 0.0):
                    if reading_val >= high_val or reading_val <= low_val:
                        extra_state = 2
                        extra_text += " (device lower/upper crit at %f/%f%s)" % (low_val, high_val, unit)

            final_state = "OK" if extra_state == 0 else ("WARN" if extra_state == 1 else ("CRIT" if extra_state == 2 else "UNKNOWN"))
            summary = infotext
            if extra_text:
                summary += ", " + extra_text

            return {
                "changed": False,
                "msg": summary,
                "data": {
                    "state": final_state,
                    "metrics": {"user": reading_val},
                    "details": "",
                },
            }

    # Item not found
    return {
        "changed": False,
        "msg": "item not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }
