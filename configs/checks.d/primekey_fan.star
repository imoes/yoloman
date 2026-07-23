# Constants for OID paths
FAN_OID_BASE = ".1.3.6.1.4.1.22408.1.1.2.1.4.102.97.110"
FAN_OIDS = [
    "49.1",  # rpm cpu fan
    "50.1",  # rpm system fan 1
    "51.1",  # rpm system fan 2
    "52.1",  # rpm system fan 3
    "53.1",  # status cpu fan
    "54.1",  # status system fans
]
DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_VALUE = ".1.3.6.1.4.1.8072.3.2.10"

# Fan item names mapping to index in the parsed data
FAN_NAMES = ["CPU", "1", "2", "3"]


def _discover_fans(ctx, params):
    # Detect if this is a PrimeKey device
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), DETECT_OID], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "discovery failed", "data": {"discovery": []}}
    
    found = False
    for line in res.stdout.splitlines():
        if line.strip().endswith(" = " + DETECT_VALUE):
            found = True
            break
    
    if not found:
        return {"changed": False, "msg": "not a PrimeKey device", "data": {"discovery": []}}
    
    # Fetch all fan data in one SNMP walk
    base_oid = FAN_OID_BASE
    all_oids = [base_oid + "." + oid for oid in FAN_OIDS]
    
    # Build snmpget command for multiple OIDs (snmpwalk on base OID gives all)
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), base_oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "fan discovery failed", "data": {"discovery": []}}
    
    # Parse snmpwalk output: OID = TYPE: value
    values = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_path = parts[0].strip()
        value_part = parts[1].strip()
        # Extract the last number from OID (e.g., "1.3.6.1.4.1.22408.1.1.2.1.4.102.97.110.49.1" -> "49.1")
        oid_suffix = oid_path.rsplit(".", 1)[-1] if "." in oid_path else ""
        if oid_suffix in FAN_OIDS:
            # Extract value after type prefix (INTEGER: or Gauge32: etc.)
            if ":" in value_part:
                value_str = value_part.split(":", 1)[1].strip()
                values[oid_suffix] = value_str
            else:
                values[oid_suffix] = value_part
    
    # Check required OIDs are present
    if len(values) != 6:
        return {"changed": False, "msg": "fan discovery failed: incomplete data", "data": {"discovery": []}}
    
    # Build fan section data as Checkmk's parse function would
    # Map OIDs to indices: 49.1->0, 50.1->1, 51.1->2, 52.1->3, 53.1->4, 54.1->5
    oid_index = {"49.1": 0, "50.1": 1, "51.1": 2, "52.1": 3, "53.1": 4, "54.1": 5}
    data = [""] * 6
    for oid_suffix, value in values.items():
        if oid_suffix in oid_index:
            data[oid_index[oid_suffix]] = value
    
    # Check if we have all values
    if "" in data:
        return {"changed": False, "msg": "fan discovery failed: incomplete data", "data": {"discovery": []}}
    
    system_fans_failed = bool(int(data[5]))
    cpu_fan_failed = bool(int(data[4]))
    
    # Build fan section
    fan_section = {
        "1": {"speed": float(data[1]), "state_fail": system_fans_failed},
        "2": {"speed": float(data[2]), "state_fail": system_fans_failed},
        "3": {"speed": float(data[3]), "state_fail": system_fans_failed},
        "CPU": {"speed": float(data[0]), "state_fail": cpu_fan_failed},
    }
    
    discovery_items = []
    for item in fan_section.keys():
        # Suggested params match Checkmk default: {"lower": (1000, 0), "output_metrics": True}
        discovery_items.append({
            "item": item,
            "params": {"lower": [1000, 0], "output_metrics": True},
            "metrics": ["speed"],
        })
    
    return {"changed": False, "msg": "discovered %d fans" % len(discovery_items),
            "data": {"discovery": discovery_items}}


def _check_fan(ctx, params):
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item provided", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch fan data via snmpget (single OID)
    base_oid = FAN_OID_BASE
    all_oids = [base_oid + "." + oid for oid in FAN_OIDS]
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost")] + all_oids, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch fan data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse snmpget output: each line: OID = TYPE: value
    values = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_path = parts[0].strip()
        value_part = parts[1].strip()
        # Extract the last number from OID
        oid_suffix = oid_path.rsplit(".", 1)[-1] if "." in oid_path else ""
        if oid_suffix in FAN_OIDS:
            if ":" in value_part:
                value_str = value_part.split(":", 1)[1].strip()
                values[oid_suffix] = value_str
            else:
                values[oid_suffix] = value_part
    
    # Check required OIDs are present
    if len(values) != 6:
        return {"changed": False, "msg": "incomplete fan data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Map OIDs to indices: 49.1->0, 50.1->1, 51.1->2, 52.1->3, 53.1->4, 54.1->5
    oid_index = {"49.1": 0, "50.1": 1, "51.1": 2, "52.1": 3, "53.1": 4, "54.1": 5}
    data = [""] * 6
    for oid_suffix, value in values.items():
        if oid_suffix in oid_index:
            data[oid_index[oid_suffix]] = value
    
    # Build fan section
    system_fans_failed = bool(int(data[5]))
    cpu_fan_failed = bool(int(data[4]))
    
    fan_section = {
        "1": {"speed": float(data[1]), "state_fail": system_fans_failed},
        "2": {"speed": float(data[2]), "state_fail": system_fans_failed},
        "3": {"speed": float(data[3]), "state_fail": system_fans_failed},
        "CPU": {"speed": float(data[0]), "state_fail": cpu_fan_failed},
    }
    
    # Check if requested item exists
    if item not in fan_section:
        return {"changed": False, "msg": "fan item %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    fan = fan_section[item]
    
    # Extract thresholds from params (match Checkmk default: {"lower": (1000, 0), "output_metrics": True})
    warn_lower = 1000
    crit_lower = 0
    output_metrics = True
    
    # Parse params if provided (Checkmk format: {"lower": (warn, crit), "output_metrics": bool})
    if "lower" in params:
        lower = params["lower"]
        if type(lower) == "list":
            warn_lower = float(lower[0]) if len(lower) > 0 else 1000
            crit_lower = float(lower[1]) if len(lower) > 1 else 0
    
    # Check thresholds: lower levels -> WARN if value <= warn, CRIT if value <= crit
    speed = fan.speed
    state = "OK"
    details = ""
    
    if fan.state_fail:
        state = "CRIT"
        details = "Status %s fan not OK" % item
    
    # Check speed thresholds only if fan is not already critical
    if state == "OK":
        if speed <= crit_lower:
            state = "CRIT"
        elif speed <= warn_lower:
            state = "WARN"
    
    # Build metrics
    metrics = {}
    if output_metrics or state != "OK":
        metrics["speed"] = speed
    
    # Build message
    msg = "Speed: %f RPM" % speed
    if fan.state_fail:
        msg += ", Status not OK"
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}


def main(ctx, params):
    if params.get("_discover"):
        return _discover_fans(ctx, params)
    return _check_fan(ctx, params)