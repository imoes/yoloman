# Discovery metrics map: each item exposes only the 'status' metric
METRIC_NAME = "status"

def main(ctx, params):
    if params.get("_discover"):
        # Fetch temperature sensor states via SNMP
        # base OID: .1.3.6.1.4.1.9.9.13.1.3.1
        # OID 2: ciscoEnvMonTemperatureStatusDescr (name)
        # OID 6: ciscoEnvMonTemperatureState (state)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.9.9.13.1.3.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        # Parse SNMP output: lines like ".1.3.6.1.4.1.9.9.13.1.3.1.2.1 = STRING: "Sensor 1" ...
        # We need to pair descr (OID .2.x) with state (OID .6.x)
        # Strategy: extract all .2 and .6 entries, then match by index suffix
        lines = res.stdout.splitlines()
        names = {}
        states = {}
        for line in lines:
            parts = line.split()
            if len(parts) < 3:
                continue
            oid_full = parts[0].rstrip("=")
            value = " ".join(parts[2:]).strip('"')
            # Extract suffix after base
            # base: .1.3.6.1.4.1.9.9.13.1.3.1
            suffix = oid_full.lstrip(".1.3.6.1.4.1.9.9.13.1.3.1.")
            if not suffix:
                continue
            # .2.x -> names, .6.x -> states
            if oid_full.endswith(".2." + suffix) or oid_full == ".1.3.6.1.4.1.9.9.13.1.3.1.2":
                names[suffix] = value
            elif oid_full.endswith(".6." + suffix) or oid_full == ".1.3.6.1.4.1.9.9.13.1.3.1.6":
                states[suffix] = value
        
        discovery = []
        # Build mapping by matching suffixes
        for suffix, name in names.items():
            state = states.get(suffix, "")
            # Only discover if state != "5" (not present)
            if state != "5":
                discovery.append({
                    "item": name,
                    "params": {},
                    "metrics": [METRIC_NAME]
                })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode: item is params.get("item", "")
    item = params.get("item", "")
    
    # Fetch the same SNMP data as in discovery
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.9.9.13.1.3.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse SNMP output and find matching item
    map_states = {
        "1": ("OK", "OK"),
        "2": ("WARN", "warning"),
        "3": ("CRIT", "critical"),
        "4": ("CRIT", "shutdown"),
        "5": ("UNKNOWN", "not present"),
        "6": ("UNKNOWN", "value out of range"),
    }
    
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        oid_full = parts[0].rstrip("=")
        # Get name (OID .2) and state (OID .6)
        if oid_full.endswith(".2") or ".2." in oid_full:
            # Extract name
            name = " ".join(parts[2:]).strip('"')
            if name == item:
                # Look for corresponding state in next lines (same suffix)
                state_oid = oid_full[:-1] + "6" if oid_full.endswith(".2") else oid_full[:-1] + "6"
                # Actually we need to find the state with same index
                # Simpler: parse all and match by name
                pass
        elif oid_full.endswith(".6") or ".6." in oid_full:
            # Extract suffix to match name
            # Actually, better approach: first collect names, then states
            pass
    
    # Re-parse more reliably: build name->state mapping
    lines = res.stdout.splitlines()
    names = {}
    states = {}
    for line in lines:
        parts = line.split()
        if len(parts) < 3:
            continue
        oid_full = parts[0].rstrip("=")
        value = " ".join(parts[2:]).strip('"')
        # Normalize: get suffix after base
        if oid_full.startswith(".1.3.6.1.4.1.9.9.13.1.3.1.2"):
            # Extract suffix part
            suffix = oid_full.lstrip(".1.3.6.1.4.1.9.9.13.1.3.1.2")
            names[suffix] = value
        elif oid_full.startswith(".1.3.6.1.4.1.9.9.13.1.3.1.6"):
            suffix = oid_full.lstrip(".1.3.6.1.4.1.9.9.13.1.3.1.6")
            states[suffix] = value
    
    # Match by name
    found = False
    for suffix, name in names.items():
        if name == item:
            state_str = states.get(suffix, "")
            state_tuple = map_states.get(state_str, ("UNKNOWN", "unknown[%s]" % state_str))
            check_state = state_tuple[0]
            state_readable = state_tuple[1]
            found = True
            # Map check_state to Starlark states
            state_map = {"OK": "OK", "WARN": "WARN", "CRIT": "CRIT", "UNKNOWN": "UNKNOWN"}
            starlark_state = state_map.get(check_state, "UNKNOWN")
            return {
                "changed": False,
                "msg": "Status: %s" % state_readable,
                "data": {
                    "state": starlark_state,
                    "metrics": {"status": 1 if starlark_state == "OK" else (2 if starlark_state == "WARN" else (3 if starlark_state == "CRIT" else 0))},
                    "details": ""
                }
            }
    
    # Not found -> UNKNOWN
    return {
        "changed": False,
        "msg": "sensor not found: %s" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
