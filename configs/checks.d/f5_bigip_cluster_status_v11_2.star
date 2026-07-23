# Constants (module top level)
STATE_NAMES_V11_2 = ["unknown", "offline", "forced offline", "standby", "active"]
STATE_NAMES_PRE_V11_2 = ["standby", "active 1", "active 2", "active"]
OID_F5_BIG_IP_bigipTrafficMgmt = ".1.3.6.1.4.1.3375.2"
OID_F5_BIG_IP_sysProductName = ".1.3.6.1.4.1.3375.2.1.4.1.0"
OID_F5_BIG_IP_sysProductVersion = ".1.3.6.1.4.1.3375.2.1.4.2.0"
OID_sysObjectID = ".1.3.6.1.2.1.1.2.0"
OID_CLUSTER_STATUS_V11_2 = ".1.3.6.1.4.1.3375.2.1.14.3.1"
OID_CLUSTER_STATUS_PRE_V11_2 = ".1.3.6.1.4.1.3375.2.1.1.1.1.19"

def main(ctx, params):
    # === DISCOVERY MODE ===
    if params.get("_discover"):
        # Detect version by querying sysObjectID and version
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), OID_sysObjectID], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Check if F5 BIG-IP device
        if res.stdout.find(OID_F5_BIG_IP_bigipTrafficMgmt) == -1:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Get product version
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), OID_F5_BIG_IP_sysProductVersion], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Extract version string (format: "STRING: X.Y.Z")
        version_str = ""
        lines = res.stdout.splitlines()
        for line in lines:
            if line.find("STRING:") != -1:
                version_str = line.split("STRING:")[1].strip().strip('"')
                break
        
        # Determine version (>= 11.2)
        is_gt_v11_2 = False
        if version_str:
            parts = version_str.split(".")
            if len(parts) >= 2:
                major_str = parts[0]
                minor_str = parts[1]
                if major_str.isdigit() and minor_str.isdigit():
                    major = int(major_str)
                    minor = int(minor_str)
                    is_gt_v11_2 = (major > 11) or (major == 11 and minor >= 2)
        
        # Get cluster status OID based on version
        base_oid = OID_CLUSTER_STATUS_V11_2 if is_gt_v11_2 else OID_CLUSTER_STATUS_PRE_V11_2
        
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), base_oid], mutates=False)
        if res.rc != 0 or res.stdout.find("No Such Object") != -1 or res.stdout.find(":") == -1:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Parse node state (single value for this check)
        node_state = None
        for line in res.stdout.splitlines():
            if line.find(": INTEGER:") != -1:
                val_part = line.split(": INTEGER:")[1].strip()
                if val_part.isdigit():
                    node_state = int(val_part)
                    break
            elif line.find(": ") != -1:
                val = line.split(": ")[1].strip()
                if val.isdigit():
                    node_state = int(val)
                    break
        
        if node_state == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Single-service check - item is ""
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [
                {"item": "", "params": {"type": "active_standby"},
                 "metrics": []}
            ]}
        }
    
    # === CHECK MODE ===
    # Get SNMP data
    is_gt_v11_2 = True  # Default to v11.2+ for the check_plugin name
    
    # Get version to determine exact OID
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost"), OID_F5_BIG_IP_sysProductVersion], mutates=False)
    if res.rc == 0:
        version_str = ""
        for line in res.stdout.splitlines():
            if line.find("STRING:") != -1:
                version_str = line.split("STRING:")[1].strip().strip('"')
                break
        if version_str:
            parts = version_str.split(".")
            if len(parts) >= 2:
                major_str = parts[0]
                minor_str = parts[1]
                if major_str.isdigit() and minor_str.isdigit():
                    major = int(major_str)
                    minor = int(minor_str)
                    is_gt_v11_2 = (major > 11) or (major == 11 and minor >= 2)
    
    base_oid = OID_CLUSTER_STATUS_V11_2 if is_gt_v11_2 else OID_CLUSTER_STATUS_PRE_V11_2
    
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost"), base_oid], mutates=False)
    
    # Parse node state
    node_state = None
    if res.rc == 0:
        for line in res.stdout.splitlines():
            if line.find(": INTEGER:") != -1:
                val_part = line.split(": INTEGER:")[1].strip()
                if val_part.isdigit():
                    node_state = int(val_part)
                    break
            elif line.find(": ") != -1:
                val = line.split(": ")[1].strip()
                if val.isdigit():
                    node_state = int(val)
                    break
    
    if node_state == None:
        return {
            "changed": False,
            "msg": "No data received from SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine state mapping
    # State 0: unknown, 1: offline, 2: forced offline, 3: standby, 4: active
    # For v11.2+, state 3=standby, 4=active are OK; others are CRIT
    # For pre-v11.2, only 3=active is OK
    state_names = STATE_NAMES_V11_2 if is_gt_v11_2 else STATE_NAMES_PRE_V11_2
    
    # State mapping for v11.2+:
    # 0->3 (unknown->standby), 1->2 (offline->forced offline), 2->2, 3->0 (standby->OK), 4->0 (active->OK)
    if is_gt_v11_2:
        # v11.2+ mapping: 0,1,2 -> CRIT/WARN, 3,4 -> OK
        if node_state == 3 or node_state == 4:
            state = "OK"
        else:
            state = "CRIT"
    else:
        # Pre-v11.2: 3=active is OK; everything else is CRIT
        if node_state == 3:
            state = "OK"
        else:
            state = "CRIT"
    
    state_summary = state_names[node_state] if node_state < len(state_names) else "unknown"
    
    return {
        "changed": False,
        "msg": "Node is " + state_summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
