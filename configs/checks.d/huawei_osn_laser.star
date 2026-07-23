# Constants for SNMP base OID and default thresholds
_LASER_BASE_OID = ".1.3.6.1.4.1.2011.2.25.3.40.50.119.10.1"
_DEFAULT_LEVELS_LOW_IN = (-160, -180)
_DEFAULT_LEVELS_LOW_OUT = (-35, -40)

def _snmp_walk(ctx, base_oid):
    """Perform SNMP walk and parse lines into a list of lists of strings."""
    res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", base_oid], mutates=False)
    if res.rc != 0:
        return []
    lines = res.stdout.splitlines()
    result = []
    for line in lines:
        # Format: OID = TYPE: value
        eq_pos = line.find("=")
        if eq_pos == -1:
            continue
        oid_part = line[:eq_pos].strip()
        value_part = line[eq_pos+1:].strip()
        # Extract value after ": "
        colon_pos = value_part.find(": ")
        if colon_pos == -1:
            continue
        value = value_part[colon_pos+2:].strip()
        result.append([oid_part, value])
    return result

def _map_laser_section(ctx):
    """
    Map SNMP data into the same structure as Checkmk's parse function:
    Each row: [item, dbm_out_10x, dbm_in_10x, fec_before, fec_after]
    """
    # Fetch all OID values in one go
    res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", _LASER_BASE_OID], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return []
    lines = res.stdout.splitlines()
    # Build a dict: oid_suffix -> value
    # We expect 5 OIDs per item: .6.200, .2.200, .2.203, .2.252, .2.253
    # OID pattern: <base>.<col>.<index>
    data = {}  # key = index, value = dict(col -> value)
    for line in lines:
        eq_pos = line.find("=")
        if eq_pos == -1:
            continue
        oid = line[:eq_pos].strip()
        val = line[eq_pos+1:].strip()
        colon_pos = val.find(": ")
        if colon_pos == -1:
            continue
        val = val[colon_pos+2:].strip()
        # Parse OID: base.col.index
        parts = oid.rsplit(".", 3)
        if len(parts) < 3:
            continue
        base_and_col = ".".join(parts[:-1])
        index = parts[-1]
        col = parts[-2]
        # We expect col in ["6", "2"] because OIDs are .6.200, .2.200, etc.
        # Actually from SNMPTree: base.OID1, OID2, ... -> OID1=6.200, OID2=2.200...
        # So OID suffix is "6.200", "2.200", etc.
        # Let's parse: base + suffix = OID without final .index
        # We'll just use the last part to group by index
        if index not in data:
            data[index] = {}
        data[index][col] = val

    # Now reconstruct section rows: [index, dbm_out_10x, dbm_in_10x, fec_before, fec_after]
    # OIDs: [6.200, 2.200, 2.203, 2.252, 2.253]
    # Columns: out (2.200), in (2.203), fec_before (2.252), fec_after (2.253), plus index
    section = []
    for index in sorted(data.keys()):
        cols = data[index]
        out_val = cols.get("2.200", "")
        in_val = cols.get("2.203", "")
        fec_before = cols.get("2.252", "")
        fec_after = cols.get("2.253", "")
        section.append([index, out_val, in_val, fec_before, fec_after])
    return section

def main(ctx, params):
    if params.get("_discover"):
        section = _map_laser_section(ctx)
        items = []
        for line in section:
            item_name = line[0]
            items.append({"item": item_name, "params": {}, "metrics": ["input_signal_power_dBm", "output_signal_power_dBm"]})
        return {
            "changed": False,
            "msg": "discovered %d lasers" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    section = _map_laser_section(ctx)
    if not section:
        return {
            "changed": False,
            "msg": "no laser data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Find the item
    found = False
    for line in section:
        if item == line[0]:
            found = True
            # Parse values
            out_raw = line[1]
            in_raw = line[2]
            fec_before = line[3]
            fec_after = line[4]

            # Convert to dBm (divide by 10)
            dbm_out = float(out_raw) / 10 if out_raw.isdigit() else None
            dbm_in = float(in_raw) / 10 if in_raw.isdigit() else None

            levels_low_in = params.get("levels_low_in", _DEFAULT_LEVELS_LOW_IN)
            levels_low_out = params.get("levels_low_out", _DEFAULT_LEVELS_LOW_OUT)

            state = "OK"
            details_parts = []

            # Check input (lower levels only)
            if dbm_in != None:
                in_val = dbm_in
                crit_low = levels_low_in[1]
                warn_low = levels_low_in[0]
                if in_val <= crit_low:
                    state = "CRIT"
                elif in_val <= warn_low:
                    state = "WARN" if state != "CRIT" else state
                details_parts.append("In: %f dBm" % in_val)
            else:
                details_parts.append("In: N/A")

            # Check output (lower levels only)
            if dbm_out != None:
                out_val = dbm_out
                crit_low = levels_low_out[1]
                warn_low = levels_low_out[0]
                if out_val <= crit_low:
                    state = "CRIT"
                elif out_val <= warn_low:
                    state = "WARN" if state != "CRIT" else state
                details_parts.append("Out: %f dBm" % out_val)
            else:
                details_parts.append("Out: N/A")

            # FEC
            if fec_before != "" and fec_after != "":
                details_parts.append("FEC: %s/%s" % (fec_before, fec_after))

            metrics = {}
            if dbm_in != None:
                metrics["input_signal_power_dBm"] = dbm_in
            if dbm_out != None:
                metrics["output_signal_power_dBm"] = dbm_out

            return {
                "changed": False,
                "msg": " ".join(details_parts),
                "data": {
                    "state": state,
                    "metrics": metrics,
                    "details": ""
                }
            }

    # Item not found
    return {
        "changed": False,
        "msg": "laser item '%s' not found" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }