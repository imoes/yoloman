def main(ctx, params):
    if params.get("_discover"):
        # Discovery: check if HA is installed by querying OID 2620.1.5.2.0
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), ".1.3.6.1.4.1.2620.1.5.2.0"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovery failed: SNMP error",
                    "data": {"discovery": []}}
        
        # Parse OID value: expect ".1.3.6.1.4.1.2620.1.5.2.0 = INTEGER: 0 or 1"
        installed = None
        for line in res.stdout.splitlines():
            if line.find(".1.3.6.1.4.1.2620.1.5.2.0") >= 0:
                # Extract value after " = "
                parts = line.split(" = ")
                if len(parts) >= 2:
                    val_str = parts[1].strip()
                    # Handle INTEGER: prefix
                    if val_str.startswith("INTEGER:"):
                        val_str = val_str[8:].strip()
                    if val_str.isdigit():
                        installed = int(val_str)
                        break
        
        # Service is only created if installed == 1
        if installed == 1:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
            }
        else:
            return {
                "changed": False,
                "msg": "discovered 0 items (HA not installed)",
                "data": {"discovery": []}
            }

    # Check mode for single item (item is always "" for this check)
    # Fetch all OIDs in one call: .1.3.6.1.4.1.2620.1.5.{2,3,4,5,6,7,101,103}
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2620.1.5.2", ".1.3.6.1.4.1.2620.1.5.3",
        ".1.3.6.1.4.1.2620.1.5.4", ".1.3.6.1.4.1.2620.1.5.5",
        ".1.3.6.1.4.1.2620.1.5.6", ".1.3.6.1.4.1.2620.1.5.7",
        ".1.3.6.1.4.1.2620.1.5.101", ".1.3.6.1.4.1.2620.1.5.103"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "HA Status UNKNOWN: SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse all values into a dict by OID suffix
    data = {}
    for line in res.stdout.splitlines():
        # Format: "<OID>.<suffix> = <type>: <value>" or "<OID>.<suffix> = <value>"
        if line.find(" = ") >= 0:
            oid_part, val_part = line.split(" = ", 1)
            # Extract suffix from OID
            if oid_part.endswith(".2"):
                data["installed"] = val_part
            elif oid_part.endswith(".3"):
                data["major"] = val_part
            elif oid_part.endswith(".4"):
                data["minor"] = val_part
            elif oid_part.endswith(".5"):
                data["started"] = val_part
            elif oid_part.endswith(".6"):
                data["state"] = val_part
            elif oid_part.endswith(".7"):
                data["block_state"] = val_part
            elif oid_part.endswith(".101"):
                data["stat_code"] = val_part
            elif oid_part.endswith(".103"):
                data["stat_long"] = val_part

    # Extract values with safe parsing
    installed_str = data.get("installed", "").strip()
    installed = None
    if installed_str.startswith("INTEGER:"):
        val = installed_str[8:].strip()
        if val.isdigit():
            installed = int(val)
    if installed == None:
        # Try without INTEGER: prefix
        val = installed_str.strip()
        if val.isdigit():
            installed = int(val)

    # HA not installed
    if installed == 0:
        return {
            "changed": False,
            "msg": "Not installed",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }

    # Extract and clean values
    major_str = data.get("major", "").strip()
    if major_str.startswith("INTEGER:"):
        major_str = major_str[8:].strip()
    major = int(major_str) if major_str.isdigit() else 0

    minor_str = data.get("minor", "").strip()
    if minor_str.startswith("INTEGER:"):
        minor_str = minor_str[8:].strip()
    minor = int(minor_str) if minor_str.isdigit() else 0

    started = data.get("started", "").strip().lower()
    if started.startswith("string:"):
        started = started[7:].strip().strip('"').strip("'").lower()
    elif started.startswith("INTEGER:"):
        started = started[8:].strip()

    state = data.get("state", "").strip()
    if state.startswith("STRING:"):
        state = state[7:].strip().strip('"').strip("'")
    elif state.startswith("INTEGER:"):
        state = state[8:].strip()

    block_state = data.get("block_state", "").strip().lower()
    if block_state.startswith("STRING:"):
        block_state = block_state[7:].strip().strip('"').strip("'").lower()
    elif block_state.startswith("INTEGER:"):
        block_state = block_state[8:].strip()

    stat_code_str = data.get("stat_code", "").strip()
    stat_code = 0
    if stat_code_str.startswith("INTEGER:"):
        val = stat_code_str[8:].strip()
        if val.isdigit():
            stat_code = int(val)
    if stat_code == 0 and stat_code_str.strip().isdigit():
        stat_code = int(stat_code_str.strip())

    stat_long = data.get("stat_long", "").strip()
    if stat_long.startswith("STRING:"):
        stat_long = stat_long[7:].strip().strip('"').strip("'")

    # Build results
    # First check: installed OK
    results = []
    results.append({"state": "OK", "summary": "Installed: v%d.%d" % (major, minor)})

    # Second check: started
    started_ok_vals = ["yes"]
    if started in started_ok_vals:
        status = "OK"
    else:
        status = "CRIT"
    results.append({"state": status, "summary": "Started: %s" % started})

    # Third check: status (state)
    state_ok_vals = ["active", "standby"]
    if state.lower() in state_ok_vals:
        status = "OK"
    else:
        status = "CRIT"
    results.append({"state": status, "summary": "Status: %s" % state})

    # Fourth check: blocking (block_state)
    block_ok_vals = ["ok"]
    block_warn_vals = ["initializing"]
    if block_state in block_ok_vals:
        status = "OK"
    elif block_state in block_warn_vals:
        status = "WARN"
    else:
        status = "CRIT"
    results.append({"state": status, "summary": "Blocking: %s" % block_state})

    # Fifth check: problem (stat_code)
    if stat_code != 0:
        results.append({"state": "CRIT", "summary": "Problem: %s" % stat_long})

    # Determine overall state (CRIT > WARN > OK)
    overall = "OK"
    for r in results:
        if r["state"] == "CRIT":
            overall = "CRIT"
            break
        elif r["state"] == "WARN" and overall != "CRIT":
            overall = "WARN"

    # Build final message (concatenate all summaries)
    summary_parts = [r["summary"] for r in results]
    msg = ", ".join(summary_parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": overall, "metrics": {}, "details": ""}
    }
