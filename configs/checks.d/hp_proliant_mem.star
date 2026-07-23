# Memory type mapping from Checkmk library
MAP_TYPES_MEMORY = {
    "1": "other",
    "2": "board",
    "3": "cpqSingleWidthModule",
    "4": "cpqDoubleWidthModule",
    "5": "simm",
    "6": "pcmcia",
    "7": "compaq-specific",
    "8": "DIMM",
    "9": "smallOutlineDimm",
    "10": "RIMM",
    "11": "SRIMM",
    "12": "FB-DIMM",
    "13": "DIMM DDR",
    "14": "DIMM DDR2",
    "15": "DIMM DDR3",
    "16": "DIMM FBD2",
    "17": "FB-DIMM DDR2",
    "18": "FB-DIMM DDR3",
    "19": "DIMM DDR4",
    "20": "HPE Specific",
    "21": "DIMM DDR5",
}

# Status mapping (from Checkmk source)
_STATUS_MAP = {
    "1": "other",
    "2": "notPresent",
    "3": "present",
    "4": "good",
    "5": "add",
    "6": "upgrade",
    "7": "missing",
    "8": "doesNotMatch",
    "9": "notSupported",
    "10": "badConfig",
    "11": "degraded",
    "12": "spare",
    "13": "partial",
}

# Condition mapping (from Checkmk source)
_CONDITION_MAP = {
    "1": "other",
    "2": "ok",
    "3": "degraded",
    "4": "degradedModuleIndexUnknown",
}

# State mappings (from Checkmk source)
_MEM_TEXT2STATE_MAP = {
    "other": "UNKNOWN",
    "notPresent": "UNKNOWN",
    "present": "WARN",
    "good": "OK",
    "add": "WARN",
    "upgrade": "WARN",
    "missing": "CRIT",
    "doesNotMatch": "CRIT",
    "notSupported": "CRIT",
    "badConfig": "CRIT",
    "degraded": "CRIT",
    "spare": "OK",
    "partial": "WARN",
}

_COND_TEXT2STATE_MAP = {
    "other": "UNKNOWN",
    "ok": "OK",
    "degraded": "CRIT",
    "failed": "CRIT",
    "degradedModuleIndexUnknown": "UNKNOWN",
}


def _parse_memory_modules(output_lines):
    """Parse the snmpwalk output into memory module data."""
    modules = {}
    for line in output_lines:
        parts = line.split(",")
        if len(parts) < 8:
            continue
        
        mod_num, board_num, cpu_num, size, typ, serial, status, condition = parts[:8]
        
        # Skip if size is not numeric
        if not size.isdigit():
            continue
        
        size_bytes = int(size) * 1024
        
        module = {
            "number": mod_num,
            "board": board_num,
            "cpu_num": int(cpu_num),
            "size": size_bytes,
            "typ": MAP_TYPES_MEMORY.get(typ, "unknown (" + typ + ")"),
            "serial": serial,
            "status": _STATUS_MAP.get(status, "unknown (" + status + ")"),
            "condition": _CONDITION_MAP.get(condition, "unknown (" + condition + ")"),
        }
        modules[mod_num] = module
    
    return modules


def main(ctx, params):
    # Handle discovery mode
    if params.get("_discover"):
        # Run SNMP walk for memory modules
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.232.6.2.14.13.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        # Parse the output into structured data
        # SNMP walk output format: OID = TYPE: value
        output_lines = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Extract the value after the last '='
            if "=" in line:
                value_part = line.rsplit("=", 1)[1].strip()
                output_lines.append(value_part)
        
        if not output_lines:
            return {"changed": False, "msg": "No memory modules found",
                    "data": {"discovery": []}}
        
        # Parse modules
        modules = _parse_memory_modules(output_lines)
        
        # Build discovery result (only modules with size > 0 and status != "notPresent")
        discovery = []
        for mod_num, mod_data in modules.items():
            if mod_data["size"] > 0 and mod_data["status"] != "notPresent":
                # For this check, item is the module number
                discovery.append({
                    "item": mod_num,
                    "params": {},
                    "metrics": []
                })
        
        return {"changed": False, "msg": "discovered %d memory modules" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Normal check mode
    item = params.get("item", "")
    
    # Run SNMP walk to get memory modules
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.232.6.2.14.13.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the output
    output_lines = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if "=" in line:
            value_part = line.rsplit("=", 1)[1].strip()
            output_lines.append(value_part)
    
    modules = _parse_memory_modules(output_lines)
    
    # Get the requested module
    if item not in modules:
        return {"changed": False, "msg": "memory module not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    module = modules[item]
    
    # Determine states
    mem_state = _MEM_TEXT2STATE_MAP.get(module["status"], "UNKNOWN")
    cond_state = _COND_TEXT2STATE_MAP.get(module["condition"], "UNKNOWN")
    
    # Determine overall state (worst of mem and condition)
    if mem_state == "CRIT" or cond_state == "CRIT":
        state = "CRIT"
    elif mem_state == "WARN" or cond_state == "WARN":
        state = "WARN"
    else:
        state = "OK"
    
    # Build summary message
    size_str = str(module["size"]) + " bytes"
    if module["size"] >= 1024 * 1024 * 1024:
        size_str = "%f GB" % (module["size"] / (1024.0 * 1024 * 1024))
    elif module["size"] >= 1024 * 1024:
        size_str = "%f MB" % (module["size"] / (1024.0 * 1024))
    
    msg_parts = [
        "Board: " + module["board"],
        "Number: " + module["number"],
        "Type: " + module["typ"],
        "Size: " + size_str,
        "Status: " + module["status"] + " (" + mem_state + ")",
        "Condition: " + module["condition"] + " (" + cond_state + ")"
    ]
    
    return {"changed": False, "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {}, "details": ""}}