# Sensor type mapping from Checkmk
_SENSOR_TYPES = {
    "4": (None, "access"),
    "12": (None, "humidity"),
    "13": ("normally open", "user"),
    "14": ("normally closed", "user"),
    "23": (None, "flow"),
    "30": (None, "current"),
    "31": (None, "status"),
    "32": (None, "position"),
    "40": ("1", "blower"),
    "41": ("2", "blower"),
    "42": ("3", "blower"),
    "43": ("4", "blower"),
    "44": ("5", "blower"),
    "45": ("6", "blower"),
    "46": ("7", "blower"),
    "47": ("8", "blower"),
    "48": ("Server in 1", "temp"),
    "49": ("Server out 1", "temp"),
    "50": ("Server in 2", "temp"),
    "51": ("Server out 2", "temp"),
    "52": ("Server in 3", "temp"),
    "53": ("Server out 3", "temp"),
    "54": ("Server in 4", "temp"),
    "55": ("Server out 4", "temp"),
    "56": ("Overview Server in", "temp"),
    "57": ("Overview Server out", "temp"),
    "58": ("Water in", "temp"),
    "59": ("Water out", "temp"),
    "60": (None, "flow"),
    "61": (None, "blowergrade"),
    "62": (None, "regulator"),
}

# Status mapping: status_code -> (state, description)
_MAP_SENSOR_STATE = {
    "1": ("UNKNOWN", "not available"),
    "2": ("CRIT", "lost"),
    "3": ("WARN", "changed"),
    "4": ("OK", "ok"),
    "5": ("CRIT", "off"),
    "6": ("OK", "on"),
    "7": ("WARN", "warning"),
    "8": ("CRIT", "too low"),
    "9": ("CRIT", "too high"),
    "10": ("CRIT", "error"),
}

# Unit suffix mapping
_MAP_UNIT = {
    "access": "",
    "current": " A",
    "status": "",
    "position": "",
    "temp": " C",
    "blower": " RPM",
    "blowergrade": "",
    "humidity": "%",
    "flow": " l/min",
    "regulator": "%",
    "user": "",
}

def _extract_tree_and_index(item):
    """Extract tree and index from item name like '1 - 3.2' or '3.2'"""
    if item.find(" - ") >= 0:
        parts = item.split(" - ")
        if len(parts) == 2:
            tree_part = parts[1].split(".")[0]
            idx_part = parts[1].split(".")[1]
            return tree_part, idx_part
    else:
        parts = item.split(".")
        if len(parts) >= 2:
            return parts[0], parts[1]
    return "", ""

def _parse_snmp_output(res):
    """Helper to extract values from snmpwalk output"""
    if res.rc != 0 or not res.stdout:
        return []

    values = []
    for line in res.stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        # Value may be prefixed by type (e.g., Gauge32: 123)
        val = parts[1].strip()
        # Extract numeric value if prefixed
        if val.find(":") >= 0:
            val = val.split(":", 1)[1].strip()
        values.append(val)
    return values

def _get_tree_base_oid(tree_num):
    """Get base OID for a tree number"""
    return ".1.3.6.1.4.1.2606.4.2." + str(tree_num)

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk all SNMP trees and enumerate access sensors
        all_items = []
        # Process trees 3, 4, 5, 6
        for tree_num in ["3", "4", "5", "6"]:
            base_oid = _get_tree_base_oid(tree_num)
            
            # Get the index column first
            index_oid = base_oid + ".5.2.1.1"
            res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                          params.get("host", "localhost"), index_oid], mutates=False)
            if res.rc != 0 or not res.stdout:
                continue

            # Extract indices from output
            indices = []
            for line in res.stdout.strip().split("\n"):
                if not line.strip():
                    continue
                parts = line.strip().split(" = ")
                if len(parts) < 2:
                    continue
                oid_str = parts[0].strip()
                # Get the last part after the base
                oid_suffix = oid_str.replace(base_oid + ".5.2.1.1.", "")
                if oid_suffix.isdigit():
                    indices.append(oid_suffix)

            # Now gather all columns for these indices
            typeid_values = _parse_snmp_output(
                ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                        params.get("host", "localhost"), base_oid + ".5.2.1.2"], mutates=False))
            status_values = _parse_snmp_output(
                ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                        params.get("host", "localhost"), base_oid + ".5.2.1.4"], mutates=False))
            reading_values = _parse_snmp_output(
                ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                        params.get("host", "localhost"), base_oid + ".5.2.1.5"], mutates=False))
            desc_values = _parse_snmp_output(
                ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                        params.get("host", "localhost"), base_oid + ".7.2.1.2"], mutates=False))

            # Build sensor records for access type
            for i in range(len(indices)):
                if i >= len(typeid_values):
                    continue
                typeid = typeid_values[i]
                if typeid not in _SENSOR_TYPES:
                    continue
                sensor_spec = _SENSOR_TYPES[typeid]
                if sensor_spec[1] != "access":
                    continue

                item_name = ""
                if sensor_spec[0] != None:
                    item_name = sensor_spec[0] + " - " + tree_num + "." + indices[i]
                else:
                    item_name = tree_num + "." + indices[i]

                # Suggested params: empty dict (Checkmk default)
                all_items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": ["access"]
                })

        return {
            "changed": False,
            "msg": "discovered %d access sensors" % len(all_items),
            "data": {"discovery": all_items}
        }

    # Check mode: examine one access sensor
    item = params.get("item", "")
    
    # Extract tree and index from item name
    tree_num, idx = _extract_tree_and_index(item)
    if not tree_num or not idx:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    base_oid = _get_tree_base_oid(tree_num)
    
    # Gather all required columns for this item
    typeid_oid = base_oid + ".5.2.1.2"
    status_oid = base_oid + ".5.2.1.4"
    reading_oid = base_oid + ".5.2.1.5"
    high_oid = base_oid + ".5.2.1.6"
    low_oid = base_oid + ".5.2.1.7"
    warn_oid = base_oid + ".5.2.1.8"
    desc_oid = base_oid + ".7.2.1.2"

    typeid_values = _parse_snmp_output(
        ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                params.get("host", "localhost"), typeid_oid], mutates=False))
    status_values = _parse_snmp_output(
        ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                params.get("host", "localhost"), status_oid], mutates=False))
    reading_values = _parse_snmp_output(
        ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                params.get("host", "localhost"), reading_oid], mutates=False))
    high_values = _parse_snmp_output(
        ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                params.get("host", "localhost"), high_oid], mutates=False))
    low_values = _parse_snmp_output(
        ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                params.get("host", "localhost"), low_oid], mutates=False))
    warn_values = _parse_snmp_output(
        ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                params.get("host", "localhost"), warn_oid], mutates=False))
    desc_values = _parse_snmp_output(
        ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                params.get("host", "localhost"), desc_oid], mutates=False))

    # Find the value at our index position (1-based indexing in SNMP output)
    idx_int = int(idx)
    if idx_int <= 0 or idx_int > len(typeid_values):
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get values (convert to 0-based index)
    i = idx_int - 1
    typeid = typeid_values[i]
    status = status_values[i] if i < len(status_values) else ""
    reading = reading_values[i] if i < len(reading_values) else ""
    high = high_values[i] if i < len(high_values) else ""
    low = low_values[i] if i < len(low_values) else ""
    warn = warn_values[i] if i < len(warn_values) else ""
    description = desc_values[i] if i < len(desc_values) else ""

    # Map to sensor type
    sensor_type = ""
    if typeid in _SENSOR_TYPES:
        sensor_type = _SENSOR_TYPES[typeid][1]

    # Get unit
    unit = ""
    if sensor_type in _MAP_UNIT:
        unit = _MAP_UNIT[sensor_type]
    else:
        unit = ""

    # Get status info
    state_str = "UNKNOWN"
    extra_info = ""
    if status in _MAP_SENSOR_STATE:
        state_str, status_desc = _MAP_SENSOR_STATE[status]
        if description:
            extra_info = "[" + description + "] "
        # Parse reading as number safely
        reading_val = reading if reading.isdigit() else "0"
        extra_info += str(int(float(reading))) + unit
    else:
        reading_val = reading if reading.isdigit() else "0"
        extra_info = "[" + description + "] " + str(int(float(reading))) + unit if description else str(int(float(reading))) + unit

    # Check for device-level thresholds if no params provided
    current_state = state_str
    if not params:
        warn_val = float(warn) if warn.isdigit() else 0.0
        high_val = float(high) if high.isdigit() else 0.0
        low_val = float(low) if low.isdigit() else 0.0
        reading_num = float(reading_val)

        if high_val > 0 and reading_num >= high_val:
            current_state = "CRIT"
            extra_info += " (device upper crit at " + str(high_val) + unit + ")"
        elif low_val > 0 and reading_num <= low_val:
            current_state = "CRIT"
            extra_info += " (device lower crit at " + str(low_val) + unit + ")"
        elif warn_val > 0 and reading_num >= warn_val:
            current_state = "WARN"

    return {
        "changed": False,
        "msg": extra_info,
        "data": {"state": current_state, "metrics": {}, "details": ""}
    }
