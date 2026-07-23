# Constants at module top level
DETECT_CIENA_OIDS = {
    "sysObjectID": ".1.3.6.1.2.1.1.2.0",
    "sysDescID": ".1.3.6.1.2.1.1.1.0",
}

CIENA_5171_PREFIXES = [".1.3.6.1.4.1.1271.1.2.11", ".1.3.6.1.4.1.6141.1.96"]

# SNMP OID definitions
BASE_OID = ".1.3.6.1.4.1.1271.2.3.1.2"
OID_END = ""
OID_CIENA_CES_PM_INSTANCE = "2.1.1.2"
OID_CIENA_CES_PM_TX_BYTES = "3.2.2.1.15"
OID_CIENA_CES_PM_RX_BYTES = "3.2.2.1.13"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            BASE_OID
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse snmpwalk output
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            
            oid_full = parts[0].strip()
            value_part = parts[1].strip()
            
            # Get last component of OID (the instance identifier)
            oid_parts = oid_full.split(".")
            if len(oid_parts) < 1:
                continue
            oid_end = oid_parts[-1]
            
            # We need to fetch all four columns for this OID
            # Use snmpget to fetch the full row for this OID index
            res_row = ctx.run([
                "snmpget",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"),
                BASE_OID + "." + OID_END + "." + oid_end,
                BASE_OID + "." + OID_CIENA_CES_PM_INSTANCE + "." + oid_end,
                BASE_OID + "." + OID_CIENA_CES_PM_TX_BYTES + "." + oid_end,
                BASE_OID + "." + OID_CIENA_CES_PM_RX_BYTES + "." + oid_end
            ], mutates=False)
            
            if res_row.rc != 0:
                continue
            
            # Parse the snmpget output
            rows = {}
            for line2 in res_row.stdout.splitlines():
                if not line2.strip():
                    continue
                parts2 = line2.strip().split(" = ")
                if len(parts2) < 2:
                    continue
                
                oid2 = parts2[0].strip()
                val2 = parts2[1].strip()
                # Extract the last component
                oid_parts2 = oid2.split(".")
                if len(oid_parts2) > 0:
                    key = oid_parts2[-1]
                    # Remove type prefix like "INTEGER:" or "STRING:"
                    if ":" in val2:
                        val2 = val2.split(":", 1)[1].strip().strip('"')
                    rows[key] = val2
            
            # Check if we have the data we need
            instance_name = rows.get(OID_CIENA_CES_PM_INSTANCE, "")
            transmit = rows.get(OID_CIENA_CES_PM_TX_BYTES, "")
            receive = rows.get(OID_CIENA_CES_PM_RX_BYTES, "")
            
            # Only include if both transmit and receive are present and non-empty
            if transmit and receive and transmit.isdigit() and receive.isdigit():
                items.append({
                    "item": instance_name,
                    "params": {},
                    "metrics": ["if_out_octets", "if_in_octets"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d routing instances" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode (normal path)
    item = params.get("item", "")
    
    # First verify the host is a CIENA 5171 by checking sysDescID
    res_desc = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        DETECT_CIENA_OIDS["sysDescID"]
    ], mutates=False)
    
    if res_desc.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for sysDescID: " + res_desc.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check if the device is a CIENA 5171
    desc_output = res_desc.stdout.strip()
    is_ciena_5171 = False
    if desc_output:
        # Extract the value part after " = "
        val_part = desc_output.split(" = ", 1)
        if len(val_part) > 1:
            val = val_part[1]
            if "5171" in val:
                is_ciena_5171 = True
    
    if not is_ciena_5171:
        return {
            "changed": False,
            "msg": "device is not a CIENA 5171",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch the routing instance data
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        BASE_OID
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse the routing instance data
    section = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        
        # Get last component of OID (the instance identifier)
        oid_parts = oid_full.split(".")
        if len(oid_parts) < 1:
            continue
        oid_end = oid_parts[-1]
        
        # We need to fetch all four columns for this OID
        res_row = ctx.run([
            "snmpget",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            BASE_OID + "." + OID_END + "." + oid_end,
            BASE_OID + "." + OID_CIENA_CES_PM_INSTANCE + "." + oid_end,
            BASE_OID + "." + OID_CIENA_CES_PM_TX_BYTES + "." + oid_end,
            BASE_OID + "." + OID_CIENA_CES_PM_RX_BYTES + "." + oid_end
        ], mutates=False)
        
        if res_row.rc != 0:
            continue
        
        # Parse the snmpget output
        rows = {}
        for line2 in res_row.stdout.splitlines():
            if not line2.strip():
                continue
            parts2 = line2.strip().split(" = ")
            if len(parts2) < 2:
                continue
            
            oid2 = parts2[0].strip()
            val2 = parts2[1].strip()
            # Extract the last component
            oid_parts2 = oid2.split(".")
            if len(oid_parts2) > 0:
                key = oid_parts2[-1]
                # Remove type prefix like "INTEGER:" or "STRING:"
                if ":" in val2:
                    val2 = val2.split(":", 1)[1].strip().strip('"')
                rows[key] = val2
        
        # Check if we have the data we need
        instance_name = rows.get(OID_CIENA_CES_PM_INSTANCE, "")
        transmit = rows.get(OID_CIENA_CES_PM_TX_BYTES, "")
        receive = rows.get(OID_CIENA_CES_PM_RX_BYTES, "")
        
        # Only include if both transmit and receive are present and non-empty
        if transmit and receive and transmit.isdigit() and receive.isdigit():
            section[instance_name] = {"transmitted": int(transmit), "received": int(receive)}
    
    # Check if the requested item exists
    if item not in section:
        return {
            "changed": False,
            "msg": "routing instance not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get the values and determine state
    transmitted = section[item]["transmitted"]
    received = section[item]["received"]
    
    # Check levels (no thresholds provided, so default to OK)
    # The original check uses check_levels_v1 with no explicit levels, meaning no thresholds
    state = "OK"
    
    return {
        "changed": False,
        "msg": "Transmitted: %d B/s, Received: %d B/s" % (transmitted, received),
        "data": {
            "state": state,
            "metrics": {"if_out_octets": transmitted, "if_in_octets": received},
            "details": ""
        }
    }
