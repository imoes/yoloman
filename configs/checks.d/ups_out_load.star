def main(ctx, params):
    # Default thresholds from Checkmk check_default_parameters
    warn = params.get("levels", (85, 90))
    warn_val = warn[0]
    crit_val = warn[1]

    # Discovery mode: enumerate all phase items
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.33.1.4.4.1.5"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        items = []
        # Parse output lines like ".1.3.6.1.2.1.33.1.4.4.1.5.1 = INTEGER: 230"
        # We only care about items where voltage (OID .1.3.6.1.2.1.33.1.4.4.1.2) is non-zero
        # We'll fetch voltage separately per candidate to avoid extra complexity
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if not stripped or "=" not in stripped:
                continue
            parts = stripped.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_path = parts[0]
            value_str = parts[1].strip()
            # Extract phase index from end of OID
            # Base OID: .1.3.6.1.2.1.33.1.4.4.1
            # Voltage OID: .1.3.6.1.2.1.33.1.4.4.1.2
            # Power OID: .1.3.6.1.2.1.33.1.4.4.1.5
            # End OID is index; value_str format: "INTEGER: <value>" or just "<value>"
            # Get last component of OID after .5
            end_oid = oid_path.rsplit(".", 1)
            if len(end_oid) < 2:
                continue
            index_str = end_oid[1]
            # Try to get voltage for this index
            voltage_oid = ".1.3.6.1.2.1.33.1.4.4.1.2." + index_str
            v_res = ctx.run([
                "snmpget", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), voltage_oid
            ], mutates=False)
            if v_res.rc != 0:
                continue
            # Parse snmpget output: ".1.3.6.1.2.1.33.1.4.4.1.2.1 = INTEGER: 230"
            v_line = v_res.stdout.strip()
            v_parts = v_line.split(" = ", 1)
            if len(v_parts) < 2:
                continue
            v_val_str = v_parts[1].strip()
            # Extract integer value
            v_val = 0
            if ":" in v_val_str:
                v_val_str = v_val_str.split(":", 1)[1].strip()
            if v_val_str.isdigit():
                v_val = int(v_val_str)
            if v_val > 0:
                items.append({
                    "item": index_str,
                    "params": {"levels": (warn_val, crit_val)},
                    "metrics": ["out_load"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d phases" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: examine one specific item (phase)
    item = params.get("item", "")
    if item == "":
        fail("item is required for check mode")
    
    # Get power value from .1.3.6.1.2.1.33.1.4.4.1.5.<item>
    power_oid = ".1.3.6.1.2.1.33.1.4.4.1.5." + item
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), power_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for phase " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output: ".1.3.6.1.2.1.33.1.4.4.1.5.1 = INTEGER: 45"
    line = res.stdout.strip()
    if not line or " = " not in line:
        return {
            "changed": False,
            "msg": "unexpected SNMP output for phase " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    parts = line.split(" = ", 1)
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "unexpected SNMP output for phase " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value_str = parts[1].strip()
    if ":" in value_str:
        value_str = value_str.split(":", 1)[1].strip()
    
    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "non-numeric load value for phase " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    power = int(value_str)
    
    # Determine state
    if power >= crit_val:
        state = "CRIT"
    elif power >= warn_val:
        state = "WARN"
    else:
        state = "OK"
    
    # Build summary message
    msg = "Phase " + item + ": " + str(power) + "% load"
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"out_load": power},
            "details": ""
        }
    }