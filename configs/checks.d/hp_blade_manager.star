_STATUS_MAP = {
    1: ("CRIT", "Other"),
    2: ("OK", "Ok"),
    3: ("WARN", "Degraded"),
    4: ("CRIT", "Failed"),
}

_ROLE_MAP = {
    1: "standby",
    2: "active"
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.232.22.2.3.1.6.1"
        ], mutates=False)
        
        entries = {}  # manager_index -> [index, present, condition, role, serial]
        
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value = parts
            # Extract instance
            instance = oid_full.rsplit(".", 1)[-1]
            if not instance.isdigit():
                continue
            
            # Map to field
            oid_base = oid_full.rsplit(".", 1)[0]
            if oid_base.endswith(".3"):
                field = 0
            elif oid_base.endswith(".10"):
                field = 1
            elif oid_base.endswith(".12"):
                field = 2
            elif oid_base.endswith(".9"):
                field = 3
            elif oid_base.endswith(".8"):
                field = 4
            else:
                continue
            
            # Extract value
            if value.startswith("INTEGER:"):
                val_str = value.split(":", 1)[1].strip()
                val = int(val_str) if val_str.isdigit() else 0
            elif value.startswith("STRING:"):
                val = value.split(":", 1)[1].strip().strip('"')
            else:
                continue
            
            if instance not in entries:
                entries[instance] = [instance, "", "", "", ""]
            entries[instance][field] = val
        
        discovery = []
        for idx_str, line in entries.items():
            present = line[1]
            role = line[3]
            
            # Only include if manager is present
            if present == 1:
                role_str = str(role) if role != "" else "2"
                discovery.append({
                    "item": str(idx_str),
                    "params": {"role": role_str},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d managers" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.232.22.2.3.1.6.1"
    ], mutates=False)
    
    entries = {}  # manager_index -> [index, present, condition, role, serial]
    
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value = parts
        instance = oid_full.rsplit(".", 1)[-1]
        if not instance.isdigit():
            continue
        
        oid_base = oid_full.rsplit(".", 1)[0]
        if oid_base.endswith(".3"):
            field = 0
        elif oid_base.endswith(".10"):
            field = 1
        elif oid_base.endswith(".12"):
            field = 2
        elif oid_base.endswith(".9"):
            field = 3
        elif oid_base.endswith(".8"):
            field = 4
        else:
            continue
        
        if value.startswith("INTEGER:"):
            val_str = value.split(":", 1)[1].strip()
            val = int(val_str) if val_str.isdigit() else 0
        elif value.startswith("STRING:"):
            val = value.split(":", 1)[1].strip().strip('"')
        else:
            continue
        
        if instance not in entries:
            entries[instance] = [instance, "", "", "", ""]
        entries[instance][field] = val
    
    for idx_str, line in entries.items():
        if str(line[0]) != item:
            continue
        
        present = line[1]
        condition = line[2]
        role = line[3]
        serial = line[4]
        
        expected_role = params.get("role", "2")
        
        # Check role first
        if str(role) != str(expected_role):
            actual_role_name = _ROLE_MAP.get(int(role), "unknown")
            expected_role_name = _ROLE_MAP.get(int(expected_role), "unknown")
            return {
                "changed": False,
                "msg": "Unexpected role: " + actual_role_name + " (Expected: " + expected_role_name + ")",
                "data": {
                    "state": "CRIT",
                    "metrics": {},
                    "details": ""
                }
            }
        
        # The SNMP answer is not fully compatible to the MIB file. The value of 0 will
        # be set to "fake OK" to display the other gathered information.
        raw_state = 2 if int(condition) == 0 else int(condition)
        state_str, state_readable = _STATUS_MAP.get(raw_state, ("UNKNOWN", "Unknown"))
        role_name = _ROLE_MAP.get(int(role), "unknown")
        
        return {
            "changed": False,
            "msg": "Enclosure Manager condition is " + state_readable + " (Role: " + role_name + ", S/N: " + str(serial) + ")",
            "data": {
                "state": state_str,
                "metrics": {},
                "details": ""
            }
        }
    
    # Item not found
    return {
        "changed": False,
        "msg": "Manager not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }