# ===== Starlark check module: ibm_tl_changer_devices =====
# Translated from Checkmk plugin cmk.plugins.ibm_tl.changer_devices
# SNMP-based check for IBM Tape Library changer devices

# State mapping from SNIA-SML-MIB
# changerDevice-Availability: 2=Degraded, 3=Online, 4=Offline, 5=OutOfService, 6=Error
# changerDevice-OperationalStatus: 1=Other, 2=OK, 3=Degraded, 4=Error

AVAILABILITY_MAP = {
    "2": "Degraded",
    "3": "Online",
    "4": "Offline",
    "5": "OutOfService",
    "6": "Error",
}

OPERATIONAL_STATUS_MAP = {
    "1": "Other",
    "2": "OK",
    "3": "Degraded",
    "4": "Error",
}


def _ibm_tape_library_get_device_state(avail, status):
    """Reproduce the lib function logic: yield state and message."""
    avail_str = AVAILABILITY_MAP.get(avail, "Unknown")
    status_str = OPERATIONAL_STATUS_MAP.get(status, "Unknown")
    
    # Determine state based on availability and status
    if avail == "3" and status == "2":
        state = "OK"
    elif avail in ["2", "4", "5", "6"] or status in ["3", "4"]:
        state = "WARN"
    else:
        state = "UNKNOWN"
    
    details = "Availability: %s, Operational status: %s" % (avail_str, status_str)
    return state, details


def _parse_snmp_output(stdout):
    """Parse the snmpwalk output for the changer devices section."""
    devices = {}
    if not stdout:
        return devices
    
    lines = stdout.split("\n")
    # We expect lines like: .1.3.6.1.4.1.14851.3.1.11.2.1.4.1 = STRING: "Logical_Library: 1"
    #                      .1.3.6.1.4.1.14851.3.1.11.2.1.8.1 = INTEGER: 3
    #                      .1.3.6.1.4.1.14851.3.1.11.2.1.9.1 = INTEGER: 2
    
    # Collect name, avail, status per index
    name_map = {}
    avail_map = {}
    status_map = {}
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        
        # Parse: OID = TYPE: value or OID:: = TYPE: value
        # Strip leading .1.3.6.1.4.1.14851.3.1.11.2.1. part to get index suffix
        if line.find(" = ") == -1:
            continue
        
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract numeric suffix (e.g., ".4.1" -> index "1")
        # Base is ".1.3.6.1.4.1.14851.3.1.11.2.1"
        # OIDs: 4 = ElementName, 8 = Availability, 9 = OperationalStatus
        base_oid = ".1.3.6.1.4.1.14851.3.1.11.2.1"
        if not oid_part.startswith(base_oid + "."):
            continue
        
        suffix = oid_part[len(base_oid) + 1:]
        # Split suffix into type and index
        dot_pos = suffix.find(".")
        if dot_pos == -1:
            continue
        
        oid_type = suffix[:dot_pos]
        index = suffix[dot_pos + 1:]
        
        # Extract value: STRING: "value", INTEGER: value
        if value_part.startswith("STRING: "):
            value = value_part[8:].strip().strip('"')
        elif value_part.startswith("INTEGER: "):
            value = value_part[9:].strip()
        else:
            continue
        
        if oid_type == "4":
            name_map[index] = value
        elif oid_type == "8":
            avail_map[index] = value
        elif oid_type == "9":
            status_map[index] = value
    
    # Build devices dict
    for index in name_map:
        name = name_map[index]
        avail = avail_map.get(index, "")
        status = status_map.get(index, "")
        # _make_item logic: remove "Logical_Library:" prefix
        item = name.replace("Logical_Library:", "").strip()
        if item:
            devices[item] = {"avail": avail, "status": status}
    
    return devices


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.14851.3.1.11.2.1"
        ], mutates=False)
        
        devices = _parse_snmp_output(res.stdout)
        discovery_list = []
        for item in devices:
            discovery_list.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d changer devices" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    # Check mode for one item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.14851.3.1.11.2.1"
    ], mutates=False)
    
    devices = _parse_snmp_output(res.stdout)
    if item not in devices:
        return {
            "changed": False,
            "msg": "device not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    device = devices[item]
    state, details = _ibm_tape_library_get_device_state(device.get("avail", ""), device.get("status", ""))
    
    return {
        "changed": False,
        "msg": "%s" % details,
        "data": {
            "state": state,
            "metrics": {},
            "details": details
        }
    }