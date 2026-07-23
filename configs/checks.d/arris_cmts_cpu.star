# Module-level constant for the SNMP OID base
_BASE_OID = ".1.3.6.1.4.1.4998.1.1.5.3.1.1.1"
_SYS_OID = ".1.3.6.1.2.1.1.2.0"
_CMTS_SYS_OID = ".1.3.6.1.4.1.4998.2.1"

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk the SNMP tree and enumerate items
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), _BASE_OID
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}

        # Parse lines into (oid_id, cpu_id, cpu_idle_util) tuples
        lines = [l for l in res.stdout.splitlines() if "=" in l]
        entries = []
        i = 0
        while i + 2 < len(lines):
            line1 = lines[i]
            line2 = lines[i+1]
            line3 = lines[i+2]
            
            # Extract values (skip type prefix like "INTEGER: " or "STRING: ")
            val1 = line1.split("=", 1)[1].strip()
            val2 = line2.split("=", 1)[1].strip()
            val3 = line3.split("=", 1)[1].strip()
            
            # Remove type prefix if present
            if ": " in val1:
                val1 = val1.split(": ", 1)[1]
            if ": " in val2:
                val2 = val2.split(": ", 1)[1]
            if ": " in val3:
                val3 = val3.split(": ", 1)[1]
            
            # Skip if any value is empty
            if val1 != "" and val3 != "":
                # Parse numeric values
                if val1.isdigit() and val3.replace(".", "", 1).isdigit():
                    oid_id_num = int(val1)
                    cpu_idle_util = float(val3)
                    
                    # Determine item name per check logic
                    cpu_id = val2
                    citem = cpu_id if cpu_id != "" else str(oid_id_num - 1)
                    
                    entries.append({
                        "item": citem,
                        "params": {"levels": (90.0, 95.0)},
                        "metrics": ["util"]
                    })
            
            i = i + 3
        
        return {"changed": False, "msg": "discovered %d modules" % len(entries),
                "data": {"discovery": entries}}

    # Check mode: single item
    item = params.get("item", "")

    # Reuse the same snmpwalk as discovery to get all data and filter by item
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), _BASE_OID
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "SNMP walk failed or no data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse lines into (oid_id, cpu_id, cpu_idle_util) tuples
    lines = [l for l in res.stdout.splitlines() if "=" in l]
    i = 0
    while i + 2 < len(lines):
        line1 = lines[i]
        line2 = lines[i+1]
        line3 = lines[i+2]
        
        # Extract values (skip type prefix like "INTEGER: " or "STRING: ")
        val1 = line1.split("=", 1)[1].strip()
        val2 = line2.split("=", 1)[1].strip()
        val3 = line3.split("=", 1)[1].strip()
        
        # Remove type prefix if present
        if ": " in val1:
            val1 = val1.split(": ", 1)[1]
        if ": " in val2:
            val2 = val2.split(": ", 1)[1]
        if ": " in val3:
            val3 = val3.split(": ", 1)[1]
        
        # Skip if any value is empty
        if val1 != "" and val3 != "":
            # Parse numeric values
            if val1.isdigit() and val3.replace(".", "", 1).isdigit():
                oid_id_num = int(val1)
                cpu_idle_util = float(val3)
                
                # Determine item name per check logic
                cpu_id = val2
                citem = cpu_id if cpu_id != "" else str(oid_id_num - 1)
                
                if citem == item:
                    # Convert idle to utilization
                    cpu_util = 100.0 - cpu_idle_util
                    warn, crit = params.get("levels", (90.0, 95.0))
                    
                    if cpu_util >= crit:
                        state = "CRIT"
                    elif cpu_util >= warn:
                        state = "WARN"
                    else:
                        state = "OK"
                    
                    return {
                        "changed": False,
                        "msg": "CPU utilization Module %s: %f%%" % (item, cpu_util),
                        "data": {
                            "state": state,
                            "metrics": {"util": cpu_util},
                            "details": ""
                        }
                    }
        
        i = i + 3

    # If item not found
    return {
        "changed": False,
        "msg": "module not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
