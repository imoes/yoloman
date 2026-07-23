def main(ctx, params):
    # Constants for SNMP OIDs (base + offsets)
    OID_BASE = ".1.3.6.1.4.1.2.3.51.2.2.6.1.1"
    OID_INDEX = OID_BASE + ".1"
    OID_PRESENT = OID_BASE + ".2"
    OID_STATUS = OID_BASE + ".3"
    OID_FANCOUNT = OID_BASE + ".4"
    OID_SPEEDPERC = OID_BASE + ".5"
    OID_RPM = OID_BASE + ".6"
    OID_CTRLSTATE = OID_BASE + ".7"

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            OID_BASE
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        # Parse snmpwalk output lines like: OID.1 = STRING: "value"
        lines = res.stdout.splitlines()
        fans = {}
        
        for line in lines:
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract OID index suffix (last number after last dot)
            suffix = oid_part.rsplit(".", 1)[-1]
            # Strip type prefix like "INTEGER: " or "STRING: "
            value = value_part.split(":", 1)[-1].strip().strip('"')
            
            # Map OIDs to fields based on offset
            # base.1=index, .2=present, .3=status, .4=fancount, .5=speedperc, .6=rpm, .7=ctrlstate
            if oid_part.endswith(".1"):  # index
                fans[suffix] = {"index": value, "present": "0"}
            elif oid_part.endswith(".2"):  # present
                fans[suffix] = fans.get(suffix, {})
                fans[suffix]["present"] = value
            elif oid_part.endswith(".3"):  # status
                fans[suffix] = fans.get(suffix, {})
                fans[suffix]["status"] = value
            elif oid_part.endswith(".4"):  # fancount
                fans[suffix] = fans.get(suffix, {})
                fans[suffix]["fancount"] = value
            elif oid_part.endswith(".5"):  # speedperc
                fans[suffix] = fans.get(suffix, {})
                fans[suffix]["speedperc"] = value
            elif oid_part.endswith(".6"):  # rpm
                fans[suffix] = fans.get(suffix, {})
                fans[suffix]["rpm"] = value
            elif oid_part.endswith(".7"):  # ctrlstate
                fans[suffix] = fans.get(suffix, {})
                fans[suffix]["ctrlstate"] = value
        
        discovery = []
        for index, fan_data in fans.items():
            present = fan_data.get("present", "0")
            if index and present == "1":
                discovery.append({
                    "item": index,
                    "params": {},
                    "metrics": ["perc", "rpm"]
                })
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode
    item = params.get("item", "")
    if not item:
        fail("item is required for check mode")
    
    # Gather data via snmpget for specific OIDs (faster and cleaner)
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        OID_INDEX + "." + item,
        OID_PRESENT + "." + item,
        OID_STATUS + "." + item,
        OID_SPEEDPERC + "." + item,
        OID_RPM + "." + item,
        OID_CTRLSTATE + "." + item
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpget failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse snmpget output: OID.1 = STRING: "value" per line
    values = {}
    lines = res.stdout.splitlines()
    for line in lines:
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Determine which OID this is by suffix
        if oid_part.endswith(".1"):
            values["index"] = value_part.split(":", 1)[-1].strip().strip('"')
        elif oid_part.endswith(".2"):
            values["present"] = value_part.split(":", 1)[-1].strip().strip('"')
        elif oid_part.endswith(".3"):
            values["status"] = value_part.split(":", 1)[-1].strip().strip('"')
        elif oid_part.endswith(".5"):
            val = value_part.split(":", 1)[-1].strip().strip('"')
            values["speedperc"] = int(val) if val.isdigit() else 0
        elif oid_part.endswith(".6"):
            val = value_part.split(":", 1)[-1].strip().strip('"')
            values["rpm"] = float(val) if val.replace('.', '').replace('-', '').isdigit() else 0.0
        elif oid_part.endswith(".7"):
            values["ctrlstate"] = value_part.split(":", 1)[-1].strip().strip('"')
    
    # Check fan presence
    present = values.get("present", "0")
    if present != "1":
        return {
            "changed": False,
            "msg": "Fan not present",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
    
    # Extract metrics
    speedperc = values.get("speedperc", 0)
    rpm = values.get("rpm", 0.0)
    status = values.get("status", "0")
    ctrlstate = values.get("ctrlstate", "0")
    
    # Determine state based on thresholds (fixed levels: lower warn=50, crit=40)
    # Checkmk uses levels_lower=("fixed", (50, 40)) → WARN if <=50, CRIT if <=40
    state = "OK"
    if speedperc <= 40:
        state = "CRIT"
    elif speedperc <= 50:
        state = "WARN"
    
    # Also check status and ctrlstate
    if status != "1":
        state = "CRIT"
    if ctrlstate != "1":
        state = "CRIT"
    
    # Build summary message
    msg = "Speed: %d%%, RPM: %d" % (speedperc, int(rpm))
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"perc": speedperc, "rpm": rpm},
            "details": ""
        },
    }
