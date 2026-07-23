# Top-level constants (required by Starlark contract)
SENSOR_TYPE = "status"

# Helper to parse SNMP walk output into a dict of sensors
def _parse_snmp_output(lines, type_):
    sensors = {}
    for line in lines:
        # Format: "<OID> = STRING: <value>" or similar
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        # Extract sensor ID from OID (last numeric component before the value type indicator)
        # Common pattern: OID ends with .<id> before .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.<type>.<id>
        # We'll grab the last component after the known prefix
        if type_ in oid_part:
            suffix = oid_part.rsplit(type_, 1)[-1].strip()
            # Extract numeric ID (e.g., ".1" -> "1")
            id_str = suffix.lstrip(".").split(".")[0]
            if not id_str.isdigit():
                continue
            sensor_id = id_str
            # Extract value (strip type prefix like "STRING: " or "INTEGER: ")
            if ":" in val_part:
                val = val_part.split(":", 1)[1].strip()
            else:
                val = val_part
            # Clean up quotes if present
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            sensors[sensor_id] = {"Status": val}
    return sensors


def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk status section via SNMP
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Walk the status OIDs — based on the source: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.*
        # We use .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6 as base and filter for status
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }
        lines = res.stdout.splitlines()
        sensors = _parse_snmp_output(lines, SENSOR_TYPE)
        use_desc = params.get("use_sensor_description", False)
        discovery = []
        # We'll need location and index — walk those too if available
        # For now, assume simple ID-based discovery if no descriptions available
        # Walk location and index OIDs if present:
        # Location: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.3 (based on CMC III MIB pattern)
        loc_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.3"
        ], mutates=False)
        locs = {}
        if loc_res.rc == 0:
            locs = _parse_snmp_output(loc_res.stdout.splitlines(), "3")
        idx_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.4"
        ], mutates=False)
        idxes = {}
        if idx_res.rc == 0:
            idxes = _parse_snmp_output(idx_res.stdout.splitlines(), "4")
        # Build discovery list
        for sid, entry in sensors.items():
            if use_desc and sid in locs and sid in idxes:
                item = "%s-%s %s" % (locs[sid], idxes[sid], entry.get("DescName", ""))
            else:
                item = sid
            discovery.append({
                "item": item,
                "params": {"_item_key": sid},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d status sensors" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode: fetch and evaluate one item
    item = params.get("item", "")
    # Get the sensor ID from params if available (compatibility with _item_key)
    sensor_id = params.get("_item_key", item)
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    # Fetch status
    # Base OID for status: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.<id>
    oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6." + str(sensor_id)
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for sensor " + str(sensor_id),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {
            "changed": False,
            "msg": "no data for sensor " + str(sensor_id),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    line = lines[0]
    # Parse: "<oid> = STRING: <value>"
    if "=" not in line:
        return {
            "changed": False,
            "msg": "malformed SNMP output for " + str(sensor_id),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    parts = line.split("=", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "malformed SNMP output for " + str(sensor_id),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    val_part = parts[1].strip()
    if ":" in val_part:
        status = val_part.split(":", 1)[1].strip()
        # Strip quotes
        if status.startswith('"') and status.endswith('"'):
            status = status[1:-1]
    else:
        status = val_part.strip()
    # Determine state
    if status == "OK":
        state = "OK"
    else:
        state = "CRIT"
    return {
        "changed": False,
        "msg": "Status: " + status,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
