# Top-level constants for status mapping
_STATE_MAP = {"0": "OK", "1": "WARN", "2": "CRIT", "3": "UNKNOWN"}
_LABEL_MAP = {"0": "Healthy", "1": "Warning", "2": "Critical", "3": "Unknown"}

def _format_item(name):
    # Replace "\\\\\\\\.\\\\" (escaped backslashes) with empty string
    # In Starlark: replace "\\\\\.\\\" pattern
    return name.replace("\\\\\\\\.\\\\", "")

def main(ctx, params):
    # DISCOVERY MODE: enumerate SMART devices
    if params.get("_discover"):
        # Walk the SNMP tree for SMART section
        base_oid = ".1.3.6.1.4.1.10876.100.1.4.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        # Parse the snmpwalk output
        # Expected lines: .1.3.6.1.4.1.10876.100.1.4.1.1.<idx> = INTEGER: <serial>
        # .1.3.6.1.4.1.10876.100.1.4.1.2.<idx> = STRING: "<name>"
        # .1.3.6.1.4.1.10876.100.1.4.1.4.<idx> = INTEGER: <status>
        items = []
        serials = {}
        names = {}
        statuses = {}
        
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Split OID and value
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            
            # Determine type by OID suffix
            suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
            if suffix == "1":
                # Serial
                idx = oid_part.rsplit(".", 2)[-2] if oid_part.count(".") >= 3 else ""
                if idx:
                    serials[idx] = val_part.strip('"')
            elif suffix == "2":
                # Name
                idx = oid_part.rsplit(".", 2)[-2] if oid_part.count(".") >= 3 else ""
                if idx:
                    names[idx] = val_part.strip('"')
            elif suffix == "4":
                # Status
                idx = oid_part.rsplit(".", 2)[-2] if oid_part.count(".") >= 3 else ""
                if idx:
                    statuses[idx] = val_part.strip('"')
        
        # Combine into items
        for idx in names:
            if idx in serials and idx in statuses:
                name = names[idx]
                formatted_name = _format_item(name)
                items.append({
                    "item": formatted_name,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d SMART devices" % len(items),
            "data": {"discovery": items}
        }
    
    # CHECK MODE: verify one SMART device
    item = params.get("item", "")
    
    # Walk the SNMP tree again for check
    base_oid = ".1.3.6.1.4.1.10876.100.1.4.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse snmpwalk output for the target item
    serials = {}
    names = {}
    statuses = {}
    
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        
        suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
        if suffix == "1":
            idx = oid_part.rsplit(".", 2)[-2] if oid_part.count(".") >= 3 else ""
            if idx:
                serials[idx] = val_part.strip('"')
        elif suffix == "2":
            idx = oid_part.rsplit(".", 2)[-2] if oid_part.count(".") >= 3 else ""
            if idx:
                names[idx] = val_part.strip('"')
        elif suffix == "4":
            idx = oid_part.rsplit(".", 2)[-2] if oid_part.count(".") >= 3 else ""
            if idx:
                statuses[idx] = val_part.strip('"')
    
    # Find matching device
    found = False
    for idx in names:
        name = names[idx]
        if _format_item(name) == item:
            found = True
            status = statuses.get(idx, "3")
            serial = serials.get(idx, "")
            
            state = _STATE_MAP.get(status, "UNKNOWN")
            label = _LABEL_MAP.get(status, "Unknown")
            msg = "(S/N %s) %s" % (serial, label)
            
            return {
                "changed": False,
                "msg": msg,
                "data": {
                    "state": state,
                    "metrics": {},
                    "details": ""
                }
            }
    
    # Device not found
    return {
        "changed": False,
        "msg": "SMART device not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }