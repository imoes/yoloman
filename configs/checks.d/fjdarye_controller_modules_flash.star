# ===== Starlark check: fjdarye_controller_modules_flash =====
# Checkmk check plugin: checkmk.fjdarye_controller_modules_flash
# Short description: Controller Module Flash %s
# Translated to Starlark for the yolo-man agent (read-only)

FJDARYE_SUPPORTED_DEVICES = [
    ".1.3.6.1.4.1.211.1.21.1.60",   # fjdarye60
    ".1.3.6.1.4.1.211.1.21.1.150",  # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153",  # fjdarye600
]

FJDARYE_ITEM_STATUS = {
    "1": "Normal",
    "2": "Alarm",
    "3": "Warning",
    "4": "Invalid",
    "5": "Maintenance",
    "6": "Undefined",
}

FJDARYE_STATUS_STATE = {
    "1": "OK",
    "2": "CRIT",
    "3": "WARN",
    "4": "CRIT",
    "5": "CRIT",
    "6": "CRIT",
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk all supported devices and collect controller module flash entries
        out = []
        for device_oid in FJDARYE_SUPPORTED_DEVICES:
            base_oid = device_oid + ".2.4.2.1"
            # SNMP walk for .1 (Index) and .3 (Status)
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), base_oid
            ], mutates=False)
            if res.rc != 0:
                continue  # skip device if snmpwalk fails
            
            for line in res.stdout.splitlines():
                parts = line.strip().split()
                if len(parts) < 2:
                    continue
                # Parse: ".OID.1 = INTEGER: 123" or ".OID.1 = 123"
                oid_part = parts[0]
                value_part = " ".join(parts[1:])
                
                # Extract index (last OID component) and status
                suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
                if suffix != "1":
                    continue
                # Extract index value (the integer)
                index_str = value_part.strip().lstrip("INTEGER: ").lstrip()
                if not index_str.isdigit():
                    continue
                index = index_str
                
                # Get status from corresponding .3 OID
                status_oid = oid_part.rsplit(".", 1)[0] + ".3"
                status_res = ctx.run([
                    "snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-On", params.get("host", "localhost"), status_oid
                ], mutates=False)
                if status_res.rc != 0:
                    continue
                
                status_line = status_res.stdout.strip()
                status_parts = status_line.split()
                if len(status_parts) < 2:
                    continue
                status_value = " ".join(status_parts[1:]).strip().lstrip("INTEGER: ").lstrip()
                if not status_value.isdigit():
                    continue
                
                status = status_value
                # Only discover if status != "4" (Invalid)
                if status != "4":
                    out.append({
                        "item": index,
                        "params": {},
                        "metrics": []
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d controller modules" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode: get status of specific item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Build list of all items by walking all devices
    section = {}
    for device_oid in FJDARYE_SUPPORTED_DEVICES:
        base_oid = device_oid + ".2.4.2.1"
        # First get all indices
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid + ".1"
        ], mutates=False)
        if res.rc != 0:
            continue
        
        indices = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid_part = parts[0]
            value_part = " ".join(parts[1:]).strip().lstrip("INTEGER: ").lstrip()
            if not value_part.isdigit():
                continue
            index = value_part
            indices[oid_part.rsplit(".", 1)[-1]] = index
        
        # Then get corresponding status for each index
        for index in indices:
            status_oid = base_oid + ".3." + index
            status_res = ctx.run([
                "snmpget", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), status_oid
            ], mutates=False)
            if status_res.rc != 0:
                continue
            
            status_line = status_res.stdout.strip()
            status_parts = status_line.split()
            if len(status_parts) < 2:
                continue
            status_value = " ".join(status_parts[1:]).strip().lstrip("INTEGER: ").lstrip()
            if not status_value.isdigit():
                continue
            
            status = status_value
            if status != "4":
                section[index] = status
    
    # Look up item in section
    if item not in section:
        return {
            "changed": False,
            "msg": "item %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    status = section[item]
    summary = FJDARYE_ITEM_STATUS.get(status, "Unknown")
    state = FJDARYE_STATUS_STATE.get(status, "UNKNOWN")
    
    return {
        "changed": False,
        "msg": "Status: %s" % summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
