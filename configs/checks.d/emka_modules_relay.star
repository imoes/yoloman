def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk the SNMP section for relays
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        # Relay table base OID: .1.3.6.1.4.1.13595.2.2.4.1
        # OID 3: coHandleModuleLink (module-link identifier)
        # OID 4: coRelayStatus (status: 1=off, 2=on)
        # OID 15: coSensorMode (optional mode)
        base_oid = ".1.3.6.1.4.1.13595.2.2.4.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oidend = parts[0].strip()
            value_str = parts[1].strip()
            # Extract relay status (integer value after ': ')
            # Format: "oidend = INTEGER: <value>"
            if value_str.startswith("INTEGER:"):
                val_part = value_str.split(":")[1].strip()
                status = int(val_part) if val_part.isdigit() else None
                if status != None and status != 1:  # only items that are not "off"
                    # Item name: last two numbers from oidend (e.g., "1.1")
                    # For clarity, derive from oidend as "Relay <last_part>"
                    item_name = "Relay " + oidend.rsplit(".", 1)[-1]
                    out.append({"item": item_name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d relays" % len(out),
                "data": {"discovery": out}}

    # Check mode: one item (relay status)
    item = params.get("item", "")
    if not item:
        fail("item is required in check mode")
    
    # Strip prefix "Relay " to get the index
    if item.startswith("Relay "):
        relay_index = item[6:]
    else:
        relay_index = item
    
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Query the relay status: base .1.3.6.1.4.1.13595.2.2.4.1 + "." + relay_index + ".4"
    # OID 4 = relay status
    base_oid = ".1.3.6.1.4.1.13595.2.2.4.1"
    full_oid = base_oid + "." + relay_index + ".4"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, full_oid], mutates=False)
    
    out = res.stdout.strip()
    if not out or "No such variable" in out or "No more variables left" in out:
        return {"changed": False, "msg": "relay %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse: "oid = INTEGER: 2"
    status = None
    if "=" in out:
        parts = out.split(" = ", 1)
        if len(parts) == 2:
            val_str = parts[1].strip()
            if val_str.startswith("INTEGER:"):
                val_part = val_str.split(":")[1].strip()
                if val_part.isdigit():
                    status = int(val_part)
    
    if status == None:
        return {"changed": False, "msg": "could not parse status for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    map_states = {
        1: ("OK", "off"),
        2: ("OK", "on"),
    }
    state_str, readable = map_states.get(status, ("UNKNOWN", "unknown state %d" % status))
    return {"changed": False, "msg": "Status: %s" % readable,
            "data": {"state": state_str, "metrics": {}, "details": ""}}
