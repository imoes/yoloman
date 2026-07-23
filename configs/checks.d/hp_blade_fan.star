PRESENT_MAP = {1: "other", 2: "absent", 3: "present"}
STATUS_MAP = {
    1: ("CRIT", "Other"),
    2: ("OK", "Ok"),
    3: ("WARN", "Degraded"),
    4: ("CRIT", "Failed"),
}

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.232.22.2.3.1.3.1"
        ], mutates=False)
        
        # Parse snmpwalk output: "OID = TYPE: value"
        entries = {}
        for line in res.stdout.splitlines():
            if " = " not in line:
                continue
            oid_part, value_part = line.rstrip().split(" = ", 1)
            # Extract base OID index
            base_oid = ".1.3.6.1.4.1.232.22.2.3.1.3.1"
            if not oid_part.startswith(base_oid + "."):
                continue
            suffix = oid_part[len(base_oid)+1:]
            value = value_part.split(": ", 1)[-1].strip().strip('"')
            if suffix == "3":
                fan_index = value
                entries[fan_index] = {"index": fan_index}
            elif suffix == "8":
                # cpqRackCommonEnclosureFanPresent
                fan_index = oid_part.split(".")[-1]
                entries.setdefault(fan_index, {})["present"] = int(value)
            elif suffix == "11":
                # cpqRackCommonEnclosureFanCondition
                fan_index = oid_part.split(".")[-1]
                entries.setdefault(fan_index, {})["condition"] = int(value)
        
        discovered = []
        for idx, data in entries.items():
            present_val = data.get("present")
            if present_val != None and PRESENT_MAP.get(int(present_val)) == "present":
                discovered.append({"item": str(idx), "params": {}, "metrics": []})
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovered),
            "data": {"discovery": discovered},
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.232.22.2.3.1.3.1"
    ], mutates=False)
    
    # Parse data for the specific fan item
    present_state = None
    condition_val = None
    
    for line in res.stdout.splitlines():
        if " = " not in line:
            continue
        oid_part, value_part = line.rstrip().split(" = ", 1)
        base_oid = ".1.3.6.1.4.1.232.22.2.3.1.3.1"
        if not oid_part.startswith(base_oid + "."):
            continue
        suffix = oid_part[len(base_oid)+1:]
        value = value_part.split(": ", 1)[-1].strip().strip('"')
        fan_index = oid_part.split(".")[-1]
        
        if fan_index != item:
            continue
        
        if suffix == "8":
            present_state = PRESENT_MAP.get(int(value))
        elif suffix == "11":
            condition_val = int(value)
    
    if present_state == None or condition_val == None:
        return {
            "changed": False,
            "msg": "fan item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    if present_state != "present":
        return {
            "changed": False,
            "msg": "FAN was present but is not available anymore (Present state: %s)" % present_state,
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }
    
    status_tuple = STATUS_MAP.get(condition_val, ("UNKNOWN", "Unknown"))
    state_str = status_tuple[0]
    readable = status_tuple[1]
    
    return {
        "changed": False,
        "msg": "FAN condition is %s" % readable,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": "",
        },
    }