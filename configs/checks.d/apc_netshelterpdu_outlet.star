# Module-level constants for SNMP OIDs
_BASE_OID = ".1.3.6.1.4.1.318.1.1.32.5.5.1"
_OID_INDEX = "2"
_OID_NAME = "3"
_OID_STATUS = "4"

def _clean_snmp_name(value):
    """Strip null bytes and strip whitespace from SNMP string values."""
    return value.replace("\x00", "").strip()

def main(ctx, params):
    # === DISCOVERY MODE ===
    if params.get("_discover"):
        # Build full OID for the table
        base = _BASE_OID
        
        # Fetch the outlet table via snmpwalk
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "snmpwalk failed",
                "data": {"discovery": []}
            }
        
        # Parse snmpwalk output: each line = "<oid>.<instance> = <type>: <value>"
        outlets = {}  # key: index (string), value: {"name": str, "status": str}
        current_index = None
        current_name = None
        current_status = None
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            
            # Split on ' = '
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            
            # Strip trailing :: from OID prefix if present
            oid_full = oid_part.strip()
            
            # Detect which OID this is based on suffix
            if oid_full.endswith("." + _OID_INDEX):
                # Extract instance (last number)
                suffix = oid_full.rsplit(".", 1)[1]
                current_index = suffix
                current_name = None
                current_status = None
                # Parse value: type is usually STRING or OCTETSTRING
                val = value_part.split(": ", 1)
                if len(val) == 2:
                    # Clean up quotes and whitespace
                    name = val[1].strip().strip('"')
                    outlets[current_index] = {"name": _clean_snmp_name(name), "status": None}
                else:
                    outlets[current_index] = {"name": "", "status": None}
                    
            elif oid_full.endswith("." + _OID_NAME):
                suffix = oid_full.rsplit(".", 1)[1]
                idx = suffix
                if idx not in outlets:
                    outlets[idx] = {"name": "", "status": None}
                val = value_part.split(": ", 1)
                if len(val) == 2:
                    name = val[1].strip().strip('"')
                    outlets[idx]["name"] = _clean_snmp_name(name)
                    
            elif oid_full.endswith("." + _OID_STATUS):
                suffix = oid_full.rsplit(".", 1)[1]
                idx = suffix
                if idx not in outlets:
                    outlets[idx] = {"name": "", "status": None}
                # Status is INTEGER
                val = value_part.split(": ", 1)
                if len(val) == 2:
                    status = val[1].strip()
                    # Ensure status is a string for comparison
                    outlets[idx]["status"] = str(status)
        
        # Build discovery list: only outlets with status "2" (on)
        discovery = []
        for idx, data in outlets.items():
            if data.get("status") == "2":
                discovery.append({
                    "item": idx,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d active outlets" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # === CHECK MODE ===
    item = params.get("item", "")
    
    # Reuse same snmpwalk as in discovery (read-only)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), _BASE_OID
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse SNMP table to find item (outlet index)
    outlets = {}
    current_index = None
    current_name = None
    current_status = None
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        oid_full = oid_part.strip()
        
        if oid_full.endswith("." + _OID_INDEX):
            suffix = oid_full.rsplit(".", 1)[1]
            current_index = suffix
            val = value_part.split(": ", 1)
            if len(val) == 2:
                name = val[1].strip().strip('"')
                current_name = _clean_snmp_name(name)
                current_status = None
            else:
                current_name = ""
                current_status = None
            outlets[current_index] = {"name": current_name, "status": current_status}
            
        elif oid_full.endswith("." + _OID_NAME):
            suffix = oid_full.rsplit(".", 1)[1]
            if suffix in outlets:
                val = value_part.split(": ", 1)
                if len(val) == 2:
                    name = val[1].strip().strip('"')
                    outlets[suffix]["name"] = _clean_snmp_name(name)
                    
        elif oid_full.endswith("." + _OID_STATUS):
            suffix = oid_full.rsplit(".", 1)[1]
            if suffix in outlets:
                val = value_part.split(": ", 1)
                if len(val) == 2:
                    status = val[1].strip()
                    outlets[suffix]["status"] = str(status)
    
    # Look up item by index
    if item not in outlets:
        return {
            "changed": False,
            "msg": "outlet not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    outlet_data = outlets[item]
    status = outlet_data.get("status")
    name = outlet_data.get("name", "Unknown")
    
    # State mapping: "2"=on -> OK, "1"=off -> WARN, else -> UNKNOWN
    state = "UNKNOWN"
    readable = "unknown"
    if status == "2":
        state = "OK"
        readable = "on"
    elif status == "1":
        state = "WARN"
        readable = "off"
    else:
        if status:
            readable = "unknown (%s)" % status
        else:
            readable = "unknown"
    
    return {
        "changed": False,
        "msg": "%s: %s" % (name, readable),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
