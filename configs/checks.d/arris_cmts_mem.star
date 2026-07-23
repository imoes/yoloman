# Memory usage for Arris CMTS modules (SNMP-based)

DISCOVERY_METRIC = "mem_used"

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.4998.1.1.5.3.2.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        items = []
        # Parse snmpwalk output lines: "<oid> = INTEGER: <value>" or similar
        for line in res.stdout.splitlines():
            line = line.strip()
            if line == "":
                continue
            # Expect format: ".1.3.6.1.4.1.4998.1.1.5.3.2.1.1.<id> = INTEGER: <cid>"
            parts = line.split("=")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract last OID component (the module ID)
            base_oid = ".1.3.6.1.4.1.4998.1.1.5.3.2.1.1."
            if not oid_part.startswith(base_oid):
                continue
            cid_str = oid_part[len(base_oid):].strip()
            # Guard before converting to int
            cid = int(cid_str) if cid_str.isdigit() else 0
            module_id = str(cid - 1)  # Checkmk parses 0-based
            
            # Now fetch the corresponding heap and heap_free values
            heap_oid = ".1.3.6.1.4.1.4998.1.1.5.3.2.1.1." + str(cid) + ".2"
            heap_free_oid = ".1.3.6.1.4.1.4998.1.1.5.3.2.1.1." + str(cid) + ".3"
            
            heap_res = ctx.run([
                "snmpget",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                heap_oid
            ], mutates=False)
            heap_free_res = ctx.run([
                "snmpget",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                heap_free_oid
            ], mutates=False)
            
            if heap_res.rc != 0 or heap_free_res.rc != 0:
                continue
            
            # Parse single OID result: "<oid> = <type>: <value>"
            heap_val = parse_snmp_value(heap_res.stdout)
            heap_free_val = parse_snmp_value(heap_free_res.stdout)
            
            if heap_val == None or heap_free_val == None:
                continue
            
            # Guard before float conversion
            heap_f = float(heap_val) if heap_val.replace(".", "").replace("-", "").isdigit() else 0.0
            heap_free_f = float(heap_free_val) if heap_free_val.replace(".", "").replace("-", "").isdigit() else 0.0
            mem_used = heap_f - heap_free_f
            mem_total = heap_f
            
            # Suggested default params
            items.append({
                "item": module_id,
                "params": {"levels": (80.0, 90.0)},
                "metrics": [DISCOVERY_METRIC]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d memory modules" % len(items),
            "data": {"discovery": items}
        }

    # CHECK MODE
    item = params.get("item", "")
    levels = params.get("levels")
    warn_pct = 80.0
    crit_pct = 90.0
    
    if levels != None and type(levels) == "list" and len(levels) == 2:
        warn_pct = float(levels[0])
        crit_pct = float(levels[1])
    
    # Get data for this module by walking the SNMP tree
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.4998.1.1.5.3.2.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Guard before converting item to int
    module_id = str(int(item) + 1) if item.isdigit() else "0"
    
    base_oid = ".1.3.6.1.4.1.4998.1.1.5.3.2.1.1." + module_id + "."
    
    heap_val = None
    heap_free_val = None
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split("=")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        if oid_part.endswith(".2"):  # heap
            heap_val = parse_snmp_value(value_part)
        elif oid_part.endswith(".3"):  # heap_free
            heap_free_val = parse_snmp_value(value_part)
    
    if heap_val == None or heap_free_val == None:
        return {
            "changed": False,
            "msg": "no data for module " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Guard before float conversion
    heap_f = float(heap_val) if heap_val.replace(".", "").replace("-", "").isdigit() else 0.0
    heap_free_f = float(heap_free_val) if heap_free_val.replace(".", "").replace("-", "").isdigit() else 0.0
    mem_used = heap_f - heap_free_f
    mem_total = heap_f
    
    if mem_total == 0:
        return {
            "changed": False,
            "msg": "total memory is zero for module " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    mem_used_pct = (mem_used / mem_total) * 100.0
    
    # Determine state based on thresholds
    if mem_used_pct >= crit_pct:
        state = "CRIT"
    elif mem_used_pct >= warn_pct:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Module %s Usage: %f%% (Total: %f MB, Used: %f MB)" % (
        item, mem_used_pct, mem_total / (1024*1024), mem_used / (1024*1024)
    )
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"mem_used": mem_used, "mem_used_pct": mem_used_pct},
            "details": ""
        }
    }


def parse_snmp_value(value_part):
    # Extract numeric value from strings like "INTEGER: 123456789" or "gauge32: 123456789"
    value_part = value_part.strip()
    if value_part == None or value_part == "":
        return None
    
    # Remove leading type prefix (e.g., "INTEGER:", "gauge32:", "Counter32:")
    idx = value_part.find(":")
    if idx >= 0:
        value_part = value_part[idx + 1:].strip()
    
    # Remove trailing units or comments
    parts = value_part.split()
    val_str = parts[0].strip() if len(parts) > 0 else value_part
    
    # Strip any non-digit characters except decimal point and minus
    cleaned = ""
    for c in val_str:
        if c.isdigit() or c in ".-+":
            cleaned += c
        else:
            break  # Stop at first non-numeric char (e.g., unit)
    
    return cleaned if cleaned != "" else None
