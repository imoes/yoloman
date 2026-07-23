# Top-level constants (module scope)
MSTATE_MAP = {
    "0": "unknown",
    "1": "deleted",
    "2": "read-only",
    "3": "read-write",
    "4": "replication destination",
    "5": "retention lock enabled",
    "6": "retention lock disabled",
}

STATE_TO_INT = {
    "unknown": 3,
    "deleted": 2,
    "read-only": 1,
    "read-write": 0,
    "replication destination": 0,
    "retention lock enabled": 0,
    "retention lock disabled": 0,
}

DEFAULT_PARAMS = {
    "deleted": 2,
    "read-only": 1,
    "read-write": 0,
    "replication destination": 0,
    "retention lock disabled": 0,
    "retention lock enabled": 0,
    "unknown": 3,
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.19746.1.15.2.1.1.2"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        # Build mapping: OID index -> mtree name (from .2)
        mtrees = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            # OID format: .1.3.6.1.4.1.19746.1.15.2.1.1.2.<index> = STRING: "<name>"
            oid = parts[0].strip()
            # Extract index from OID (last component)
            index = oid.rsplit(".", 1)[-1] if "." in oid else ""
            # Join remaining parts as value (handle quoted strings)
            value = " ".join(parts[2:]).strip('"')
            if index and value:
                mtrees[index] = value
        
        # Get status codes (OID .3)
        res_status = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.19746.1.15.2.1.1.3"
        ], mutates=False)
        if res_status.rc != 0:
            return {"changed": False, "msg": "SNMP status walk failed", "data": {"discovery": []}}
        
        status_map = {}
        for line in res_status.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            index = oid.rsplit(".", 1)[-1] if "." in oid else ""
            # Value is the third token (TYPE: value), but often just third token
            value = parts[2].strip() if len(parts) > 2 else ""
            if index and value:
                status_map[index] = value
        
        # Get precompiled bytes (OID .4)
        res_precomp = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.19746.1.15.2.1.1.4"
        ], mutates=False)
        if res_precomp.rc != 0:
            return {"changed": False, "msg": "SNMP precompiled walk failed", "data": {"discovery": []}}
        
        precomp_map = {}
        for line in res_precomp.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            index = oid.rsplit(".", 1)[-1] if "." in oid else ""
            # Value is the third token (TYPE: value)
            value = parts[2].strip() if len(parts) > 2 else ""
            if index and value:
                precomp_map[index] = value
        
        discovery = []
        for index in mtrees:
            mtree_name = mtrees.get(index, "")
            status_code = status_map.get(index, "")
            precomp_str = precomp_map.get(index, "0")
            # Parse precompiled: convert GB (float) to bytes
            precomp_gb = 0.0
            if precomp_str != "":
                precomp_gb = float(precomp_str)
            precomp_bytes = int(precomp_gb * 1024 * 1024 * 1024)
            
            if mtree_name:
                # Build default params for this mtree
                mstate_str = MSTATE_MAP.get(status_code, "unknown")
                default_params_for_item = {}
                for key, val in DEFAULT_PARAMS.items():
                    default_params_for_item[key] = val
                # Add state mapping key if needed
                default_params_for_item[mstate_str] = STATE_TO_INT.get(mstate_str, 3)
                discovery.append({
                    "item": mtree_name,
                    "params": default_params_for_item,
                    "metrics": ["precompiled"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d mtrees" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode (non-discovery)
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.19746.1.15.2.1.1.2"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Build index -> name map
    index_to_name = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid = parts[0].strip()
        index = oid.rsplit(".", 1)[-1] if "." in oid else ""
        value = " ".join(parts[2:]).strip('"')
        if index and value:
            index_to_name[index] = value
    
    # Find index for item
    target_index = ""
    for idx, name in index_to_name.items():
        if name == item:
            target_index = idx
            break
    
    if target_index == "":
        return {
            "changed": False,
            "msg": "mtree not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get status
    res_status = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.19746.1.15.2.1.1.3." + target_index
    ], mutates=False)
    if res_status.rc != 0 or res_status.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "failed to get mtree status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse status OID response: ".1.3.6.1.4.1.19746.1.15.2.1.1.3.1 = INTEGER: 3"
    status_parts = res_status.stdout.strip().split()
    status_code = ""
    if len(status_parts) >= 3:
        status_code = status_parts[-1].strip()
    
    # Get precompiled bytes
    res_precomp = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.19746.1.15.2.1.1.4." + target_index
    ], mutates=False)
    if res_precomp.rc != 0 or res_precomp.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "failed to get mtree precompiled",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    precomp_parts = res_precomp.stdout.strip().split()
    precomp_str = ""
    if len(precomp_parts) >= 3:
        precomp_str = precomp_parts[-1].strip()
    
    # Compute precompiled bytes
    precomp_bytes = 0
    if precomp_str != "":
        precomp_gb = float(precomp_str)
        precomp_bytes = int(precomp_gb * 1024 * 1024 * 1024)
    
    # Determine state
    dev_state_str = MSTATE_MAP.get(status_code, "unknown")
    state_int = params.get(dev_state_str, STATE_TO_INT.get(dev_state_str, 3))
    
    # Validate state_int (must be 0-3 for valid State values)
    if state_int in (0, 1, 2, 3):
        state = "CRIT" if state_int == 2 else ("WARN" if state_int == 1 else ("OK" if state_int == 0 else "UNKNOWN"))
    else:
        state = "UNKNOWN"
    
    return {
        "changed": False,
        "msg": "Status: " + dev_state_str + ", Precompiled: " + str(precomp_bytes) + " bytes",
        "data": {
            "state": state,
            "metrics": {"precompiled": precomp_bytes},
            "details": ""
        }
    }
