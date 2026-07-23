# ===== module-level constants =====
DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_ACME_VALUE = ".1.3.6.1.4.1.9148"

ACME_ENVIRONMENT_STATES = {
    "1": ("OK", "initial"),
    "2": ("OK", "normal"),
    "3": ("WARN", "minor"),
    "4": ("WARN", "major"),
    "5": ("CRIT", "critical"),
    "6": ("CRIT", "shutdown"),
    "7": ("CRIT", "not present"),
    "8": ("CRIT", "not functioning"),
    "9": ("CRIT", "unknown"),
}

# ===== main module entry =====
def main(ctx, params):
    # Determine mode: discovery vs. check
    if params.get("_discover"):
        # ===== DISCOVERY MODE =====
        # Check ACME detection by reading sysObjectID
        res_sysobj = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On", 
                              params.get("host", "localhost"), DETECT_OID], mutates=False)
        if res_sysobj.rc != 0 or not res_sysobj.stdout:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Extract sysObjectID value (format: OID = STRING: value)
        sysobj_line = res_sysobj.stdout.strip()
        parts = sysobj_line.split(" = ", 1)
        if len(parts) < 2:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        sysobj_value = parts[1].strip()
        
        # Only proceed if device matches ACME
        if not sysobj_value.startswith(DETECT_ACME_VALUE):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Fetch power supply data: descr and state
        base_oid = ".1.3.6.1.4.1.9148.3.3.1.5.1.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), base_oid], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Parse SNMP output
        sections = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            
            full_oid = parts[0].strip()
            value = parts[1].strip()
            # Handle type prefix (STRING:, INTEGER:, etc.)
            if ":" in value:
                value = value.split(":", 1)[1].strip().strip('"')
            
            # Determine type: OID ending with .3 = description, .4 = state
            if full_oid.endswith(".3"):
                # Description OID: extract instance index
                # Format: ...apEnvMonPowerSupplyStatusDescr.<index>
                index = full_oid.rsplit(".", 1)[-1]
                sections[index] = {"descr": value}
            elif full_oid.endswith(".4"):
                # State OID: extract instance index
                index = full_oid.rsplit(".", 1)[-1]
                if index in sections:
                    sections[index]["state"] = value
                else:
                    sections[index] = {"state": value}
        
        # Build discovery list
        items = []
        for index, data in sections.items():
            descr = data.get("descr", "unknown")
            state = data.get("state", "0")
            # Skip "not present" (state 7) per Checkmk logic
            if state != "7":
                items.append({"item": descr, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d power supplies" % len(items),
                "data": {"discovery": items}}
    
    # ===== CHECK MODE =====
    item = params.get("item", "")
    # Ensure detection first
    res_sysobj = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                          params.get("host", "localhost"), DETECT_OID], mutates=False)
    if res_sysobj.rc != 0:
        return {"changed": False, "msg": "device not detected as ACME",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysobj_line = res_sysobj.stdout.strip()
    parts = sysobj_line.split(" = ", 1)
    if len(parts) < 2:
        return {"changed": False, "msg": "device not detected as ACME",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysobj_value = parts[1].strip()
    if not sysobj_value.startswith(DETECT_ACME_VALUE):
        return {"changed": False, "msg": "device not detected as ACME",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch current power supply state for the item
    # Map item (descr) back to state OID by walking all and matching description
    base_oid = ".1.3.6.1.4.1.9148.3.3.1.5.1.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost"), base_oid], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "power supply not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state_oid = None
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        full_oid = parts[0].strip()
        value = parts[1].strip()
        # Extract value and strip type prefix
        if ":" in value:
            value = value.split(":", 1)[1].strip().strip('"')
        
        # If this is a description OID (.3) and matches our item
        if full_oid.endswith(".3") and value == item:
            # Build corresponding state OID (.4)
            idx = full_oid.rsplit(".", 1)[-1]
            state_oid = base_oid + ".4." + idx
            break
    
    # If item not found, report unknown
    if not state_oid:
        return {"changed": False, "msg": "power supply not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch the state value
    res_state = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                         params.get("host", "localhost"), state_oid], mutates=False)
    if res_state.rc != 0:
        return {"changed": False, "msg": "power supply not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse state value
    state_line = res_state.stdout.strip()
    parts = state_line.split(" = ", 1)
    if len(parts) < 2:
        return {"changed": False, "msg": "power supply not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state_value = parts[1].strip()
    if ":" in state_value:
        state_value = state_value.split(":", 1)[1].strip().strip('"')
    
    # Look up state
    lookup = ACME_ENVIRONMENT_STATES.get(state_value, ("UNKNOWN", "unknown"))
    dev_state, dev_state_readable = lookup
    
    return {"changed": False, "msg": "Status: %s" % dev_state_readable,
            "data": {"state": dev_state, "metrics": {}, "details": ""}}
