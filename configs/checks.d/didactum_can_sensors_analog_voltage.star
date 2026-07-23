def main(ctx, params):
    # SNMP base OIDs for the DIDACTUM CAN sensors analog section
    base_oid = ".1.3.6.1.4.1.46501.6.2.1"
    
    # Determine mode
    if params.get("_discover"):
        # Discovery: fetch all voltage sensors
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse the raw output
        lines = res.stdout.splitlines()
        sensors = {}  # index -> dict
        
        for line in lines:
            eq = line.find("=")
            if eq == -1:
                continue
            oid_part = line[:eq].strip()
            val_part = line[eq+1:].strip()
            
            # Extract OID tail after base
            if not oid_part.startswith(base_oid + "."):
                continue
            tail = oid_part[len(base_oid)+1:]
            
            # Split index and suffix
            dot_idx = tail.rfind(".")
            if dot_idx == -1:
                continue
            suffix = tail[:dot_idx]
            idx = tail[dot_idx+1:]
            
            # Map suffix to field
            if suffix == "4":
                val = val_part.strip('"')
                sensors.setdefault(idx, {})["name"] = val
            elif suffix == "5":
                sensors.setdefault(idx, {})["status"] = val_part
            elif suffix == "6":
                val = val_part
                if val.isdigit():
                    sensors.setdefault(idx, {})["value"] = int(val)
                else:
                    # Guard for float parsing
                    has_dot = val.find(".") != -1
                    if has_dot or val.lstrip("-").isdigit():
                        sensors.setdefault(idx, {})["value"] = float(val)
                    else:
                        sensors.setdefault(idx, {})["value"] = val
            elif suffix == "10":
                val = val_part
                if val.replace('.','',1).lstrip('-').isdigit():
                    sensors.setdefault(idx, {})["crit_lower"] = float(val)
            elif suffix == "11":
                val = val_part
                if val.replace('.','',1).lstrip('-').isdigit():
                    sensors.setdefault(idx, {})["warn_lower"] = float(val)
            elif suffix == "12":
                val = val_part
                if val.replace('.','',1).lstrip('-').isdigit():
                    sensors.setdefault(idx, {})["warn"] = float(val)
            elif suffix == "13":
                val = val_part
                if val.replace('.','',1).lstrip('-').isdigit():
                    sensors.setdefault(idx, {})["crit"] = float(val)
        
        # Yield discovery items for voltage sensors
        out = []
        for idx, s in sensors.items():
            name = s.get("name")
            status = s.get("status")
            if name and status not in ("off", "not connected"):
                # Build suggested params: include levels if available
                suggested = {}
                if "warn" in s and "crit" in s:
                    suggested["levels"] = (float(s["warn"]), float(s["crit"]))
                if "warn_lower" in s and "crit_lower" in s:
                    suggested["levels_lower"] = (float(s["warn_lower"]), float(s["crit_lower"]))
                out.append({
                    "item": name,
                    "params": suggested,
                    "metrics": ["voltage"]
                })

        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: handle one item (voltage sensor)
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base_oid
    ], mutates=False)
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)

    # Re-parse to find the sensor
    sensors = {}
    for line in res.stdout.splitlines():
        eq = line.find("=")
        if eq == -1:
            continue
        oid_part = line[:eq].strip()
        val_part = line[eq+1:].strip()
        
        if not oid_part.startswith(base_oid + "."):
            continue
        tail = oid_part[len(base_oid)+1:]
        dot_idx = tail.rfind(".")
        if dot_idx == -1:
            continue
        suffix = tail[:dot_idx]
        idx = tail[dot_idx+1:]
        
        if suffix == "4":
            val = val_part.strip('"')
            sensors.setdefault(idx, {})["name"] = val
        elif suffix == "5":
            sensors.setdefault(idx, {})["status"] = val_part
        elif suffix == "6":
            val = val_part
            if val.isdigit():
                sensors.setdefault(idx, {})["value"] = int(val)
            else:
                has_dot = val.find(".") != -1
                if has_dot or val.lstrip("-").isdigit():
                    sensors.setdefault(idx, {})["value"] = float(val)
                else:
                    sensors.setdefault(idx, {})["value"] = val
        elif suffix == "10":
            val = val_part
            if val.replace('.','',1).lstrip('-').isdigit():
                sensors.setdefault(idx, {})["crit_lower"] = float(val)
        elif suffix == "11":
            val = val_part
            if val.replace('.','',1).lstrip('-').isdigit():
                sensors.setdefault(idx, {})["warn_lower"] = float(val)
        elif suffix == "12":
            val = val_part
            if val.replace('.','',1).lstrip('-').isdigit():
                sensors.setdefault(idx, {})["warn"] = float(val)
        elif suffix == "13":
            val = val_part
            if val.replace('.','',1).lstrip('-').isdigit():
                sensors.setdefault(idx, {})["crit"] = float(val)

    # Find the sensor by item name
    data = None
    for s in sensors.values():
        if s.get("name") == item:
            # Map status to state
            status_map = {
                "alarm": "CRIT",
                "high alarm": "CRIT",
                "low alarm": "CRIT",
                "warning": "WARN",
                "high warning": "WARN",
                "low warning": "WARN",
                "normal": "OK",
                "not connected": "UNKNOWN",
                "on": "OK",
                "off": "UNKNOWN"
            }
            state_readable = s.get("status", "unknown")
            state_str = status_map.get(state_readable, "UNKNOWN")
            value = s.get("value")
            data = {
                "value": value,
                "state": state_str,
                "state_readable": state_readable,
                "levels": (s.get("warn", None), s.get("crit", None)),
                "levels_lower": (s.get("warn_lower", None), s.get("crit_lower", None))
            }
            break

    if data == None or data["value"] == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Check voltage using elphase logic (simplified)
    value = data["value"]
    state_str = data["state"]
    state_readable = data["state_readable"]
    warn, crit = data["levels"]
    warn_l, crit_l = data["levels_lower"]

    # Determine final levels from params or device levels
    levels = params.get("levels")
    levels_lower = params.get("levels_lower")
    if levels == None and warn != None and crit != None:
        levels = (float(warn), float(crit))
    if levels_lower == None and warn_l != None and crit_l != None:
        levels_lower = (float(warn_l), float(crit_l))

    # Determine final state
    state = state_str
    if levels != None and len(levels) == 2:
        w, c = levels
        if value >= c:
            state = "CRIT"
        elif value >= w:
            state = "WARN"
        else:
            if levels_lower != None and len(levels_lower) == 2:
                w_l, c_l = levels_lower
                if value <= c_l:
                    state = "CRIT"
                elif value <= w_l:
                    state = "WARN"
                else:
                    state = "OK"
    else:
        state = state_str

    # Build message
    msg = "Voltage: %f V, Status: %s" % (value, state_readable)
    metrics = {"voltage": value}

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }