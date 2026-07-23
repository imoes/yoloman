# module-level constants
DEFAULT_TEMP_WARN = 50.0
DEFAULT_TEMP_CRIT = 60.0
DEFAULT_DEVICE_LEVELS_HANDLING = "usr"

# SNMP base OID and mapping from source
SNMP_BASE_OID = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"

PSU_STATE_MAPPING = {
    "1": "OK",  # NotPresent
    "2": "OK",  # NotPlugged
    "3": "OK",  # Powered
    "4": "CRIT",  # Failed
    "5": "CRIT",  # PermFailure
    "6": "OK",  # Max
    "7": "CRIT",  # AuxFailure
    "8": "CRIT",  # NotPowered
    "9": "CRIT",  # AuxNotPowered
}


def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            SNMP_BASE_OID
        ], mutates=False)

        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }

        # Parse snmpwalk output into PSU entries
        items = []
        lines = res.stdout.splitlines()
        for line in lines:
            # Format: OID.ending = TYPE: value
            if not line.strip():
                continue
            # Extract OID ending (last component after last dot)
            parts = line.split()
            if len(parts) < 3:
                continue
            oid_part = parts[0].strip().rstrip(".")
            if oid_part.count(".") < 1:
                continue
            oid_ending = oid_part.rsplit(".", 1)[-1]
            # Extract value after ":"
            value_str = " ".join(parts[2:]).strip()
            if not value_str:
                continue
            # We need to collect all columns for one PSU (9 columns per PSU)
            # For discovery, we only need to know if we have valid PSU entries
            # The base OID is .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1
            # Then we have OIDEnd(), 2,3,4,5,6,7,8,9
            # So entries at positions 1,10,19,... are PSU entries (OIDEnd)
            # For simplicity, we'll parse by grouping based on OID structure

        # More robust parsing: group by PSU instance
        # We need to extract index (OIDEnd) and state (field 2) together
        # Let's parse again: find index and state for each PSU
        psu_entries = {}
        for line in lines:
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            oid_full = parts[0].strip().rstrip(".")
            # Extract the full OID path and determine column
            # Base: .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1
            # Columns: 1 (index), 2 (state), 3 (failures), 4 (temp), etc.
            base = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
            if not oid_full.startswith(base + "."):
                continue
            suffix = oid_full[len(base)+1:]
            if not suffix:
                continue
            # Split suffix into parts
            suffix_parts = suffix.split(".")
            if len(suffix_parts) < 1:
                continue
            # The last part is the index, the middle parts are column
            # Actually, OIDEnd() means we take the entire suffix after base
            # So if base.2 = index, then OIDEnd() is base, and column 2 is base.2
            # Let's restructure: the snmpwalk output format is:
            # .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.2.1 = INTEGER: 3
            # The last number before the value is the index (e.g., .1)
            # Column 2: state, column 3: failures, column 4: temp, etc.

        # Better parsing: parse by extracting column and index
        # We'll collect all data into a dict indexed by PSU index
        psu_data = {}
        for line in lines:
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) < 3:
                continue
            oid_full = parts[0].strip()
            # Extract OID and value
            # Example: .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.2.1 = INTEGER: 3
            # oid_full is like .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1.2.1
            # Base is .1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1
            # So the remaining OID after base has the column and index
            # Let's compute column: for .2, it's column 2, index is the last number
            if not oid_full.startswith(SNMP_BASE_OID + "."):
                continue
            suffix = oid_full[len(SNMP_BASE_OID)+1:]
            suffix_parts = suffix.split(".")
            if len(suffix_parts) < 1:
                continue
            # First part after base is column (2,3,4,...), rest is index
            col = int(suffix_parts[0])
            index = ".".join(suffix_parts[1:]) if len(suffix_parts) > 1 else ""
            value = " ".join(parts[2:])
            # Remove leading/trailing quotes/colon if present
            if value.startswith(":"):
                value = value[1:].strip()
            if value.startswith("INTEGER:"):
                value = value[8:].strip()
            elif value.startswith("STRING:"):
                value = value[7:].strip().strip('"')
            elif value.startswith("Counter32:"):
                value = value[10:].strip()
            elif value.startswith("Gauge32:"):
                value = value[8:].strip()

            if index not in psu_data:
                psu_data[index] = {}
            psu_data[index][col] = value

        # Now build items list
        discovered = []
        for index, cols in psu_data.items():
            # State is column 2
            state_str = cols.get(2, "")
            if state_str in ["1", "2"]:  # NotPresent, NotPlugged
                continue
            # Item name: model + space + index (as per parse_aruba_psu)
            model = cols.get(9, "")
            item_name = model + " " + index if model else index
            discovered.append({
                "item": item_name,
                "params": {
                    "levels": [DEFAULT_TEMP_WARN, DEFAULT_TEMP_CRIT],
                    "device_levels_handling": DEFAULT_DEVICE_LEVELS_HANDLING
                },
                "metrics": ["temp"]
            })

        return {
            "changed": False,
            "msg": "discovered %d PSUs" % len(discovered),
            "data": {"discovery": discovered}
        }

    # CHECK MODE
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Get all PSU data via SNMP walk
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        SNMP_BASE_OID
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpwalk output into PSU entries
    psu_data = {}
    lines = res.stdout.splitlines()
    for line in lines:
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        oid_full = parts[0].strip()
        if not oid_full.startswith(SNMP_BASE_OID + "."):
            continue
        suffix = oid_full[len(SNMP_BASE_OID)+1:]
        suffix_parts = suffix.split(".")
        if len(suffix_parts) < 1:
            continue
        col = int(suffix_parts[0])
        index = ".".join(suffix_parts[1:]) if len(suffix_parts) > 1 else ""
        value = " ".join(parts[2:])
        # Clean value
        if value.startswith(":"):
            value = value[1:].strip()
        if value.startswith("INTEGER:"):
            value = value[8:].strip()
        elif value.startswith("STRING:"):
            value = value[7:].strip().strip('"')
        elif value.startswith("Counter32:"):
            value = value[10:].strip()
        elif value.startswith("Gauge32:"):
            value = value[8:].strip()

        if index not in psu_data:
            psu_data[index] = {}
        psu_data[index][col] = value

    # Build section dict (item_name -> PSU info)
    section = {}
    for index, cols in psu_data.items():
        model = cols.get(9, "")
        state_str = cols.get(2, "")
        # Skip NotPresent/NotPlugged for consistency with discovery
        if state_str in ["1", "2"]:
            continue
        item_name = model + " " + index if model else index
        temp_str = cols.get(4, "")
        temp = float(temp_str) if temp_str.replace('.','').replace('-','').isdigit() else 0.0
        section[item_name] = {
            "temperature": temp,
            "state": state_str
        }

    # Find the specific PSU for this item
    psu = section.get(item)
    if psu == None:
        return {
            "changed": False,
            "msg": "PSU not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get thresholds from params
    levels = params.get("levels", [DEFAULT_TEMP_WARN, DEFAULT_TEMP_CRIT])
    warn = levels[0]
    crit = levels[1]

    # Compute state based on temperature
    temp = psu["temperature"]
    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    # Return result
    return {
        "changed": False,
        "msg": "%s %f°C" % (state, temp),
        "data": {
            "state": state,
            "metrics": {"temp": temp},
            "details": ""
        }
    }
