# Top-level constants
SNMP_BASE_OID = ".1.3.6.1.4.1.37447.1.2.1"
OID_VOLUME_ID = "2"
OID_VOLUME_NAME = "3"
OID_VOLUME_SIZE_TOTAL = "4"
OID_VOLUME_SIZE_FREE = "6"
OID_VOLUME_STATE = "10"

# Helper to parse snmpwalk output lines
def _parse_snmp_line(line):
    parts = line.strip().split(" = ")
    if len(parts) != 2:
        return None, None
    oid_with_index = parts[0].strip()
    value_part = parts[1].strip()
    # Extract OID index (e.g., ".1.3.6.1.4.1.37447.1.2.1.2.1" -> "1")
    index_start = oid_with_index.rfind(".")
    if index_start == -1:
        index = ""
    else:
        index = oid_with_index[index_start+1:]
    # Parse value type
    if value_part.startswith("STRING: "):
        value = value_part[8:-1]  # strip quotes
    elif value_part.startswith("INTEGER: "):
        value = int(value_part[9:])
    elif value_part.startswith("Gauge32: "):
        value = int(value_part[9:])
    elif value_part.startswith("Counter32: "):
        value = int(value_part[11:])
    else:
        value = value_part.strip()
    return index, value

def _gather_volume_data(ctx):
    # Build full OIDs for the section
    base = SNMP_BASE_OID
    oids = [
        base + "." + OID_VOLUME_ID,
        base + "." + OID_VOLUME_NAME,
        base + "." + OID_VOLUME_SIZE_TOTAL,
        base + "." + OID_VOLUME_SIZE_FREE,
        base + "." + OID_VOLUME_STATE
    ]
    # Run snmpwalk for each OID and collect results
    # We need to merge results by index across OIDs
    data_by_index = {}
    for oid in oids:
        res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", oid], mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            index, value = _parse_snmp_line(line)
            if index == None or value == None:
                continue
            if index not in data_by_index:
                data_by_index[index] = {}
            # Map oid suffix to field
            if oid.endswith(OID_VOLUME_ID):
                data_by_index[index]["id"] = value
            elif oid.endswith(OID_VOLUME_NAME):
                data_by_index[index]["name"] = value
            elif oid.endswith(OID_VOLUME_SIZE_TOTAL):
                data_by_index[index]["total"] = value
            elif oid.endswith(OID_VOLUME_SIZE_FREE):
                data_by_index[index]["free"] = value
            elif oid.endswith(OID_VOLUME_STATE):
                data_by_index[index]["state"] = value
    return data_by_index

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        data = _gather_volume_data(ctx)
        services = []
        for index, fields in data.items():
            state = fields.get("state")
            if state == 1:
                name = fields.get("name", "")
                services.append({
                    "item": name,
                    "params": {},  # uses default filesystem params from check_ruleset
                    "metrics": ["size_used", "size_free", "size"]
                })
        return {
            "changed": False,
            "msg": "discovered %d volumes" % len(services),
            "data": {"discovery": services}
        }
    
    # Check mode
    item = params.get("item", "")
    data = _gather_volume_data(ctx)
    
    # Find the item
    found = False
    for index, fields in data.items():
        name = fields.get("name", "")
        if name == item:
            found = True
            state = fields.get("state")
            if state == 0:
                return {
                    "changed": False,
                    "msg": "Volume is offline",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            total = int(fields.get("total", 0))
            free = int(fields.get("free", 0))
            used = total - free
            warn = params.get("warn", 80.0)
            crit = params.get("crit", 90.0)
            
            # Compute percentages
            used_percent = (float(used) / float(total) * 100.0) if total > 0 else 0.0
            
            # Determine state
            state_value = "CRIT" if used_percent >= crit else ("WARN" if used_percent >= warn else "OK")
            
            # Build metrics: Checkmk uses size_used and size_free
            metrics = {
                "size_used": used,
                "size_free": free,
                "size": total,
                "used_percent": used_percent
            }
            
            return {
                "changed": False,
                "msg": "Size: %f MB, Usage: %f%%" % (float(used) / 1024.0 / 1024.0, used_percent),
                "data": {"state": state_value, "metrics": metrics, "details": ""}
            }
    
    # Item not found
    return {
        "changed": False,
        "msg": "Volume not found",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }