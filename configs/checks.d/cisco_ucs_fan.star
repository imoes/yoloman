def main(ctx, params):
    if params.get("_discover"):
        # Discover fans by walking SNMP table: base .1.3.6.1.4.1.9.9.719.1.15.12.1
        # OID 2 = cucsEquipmentFanDn
        # OID 10 = cucsEquipmentFanOperability
        base_oid = ".1.3.6.1.4.1.9.9.719.1.15.12.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse the output: lines like "<oid>.2.<item_id> = STRING: <dn>"
        # and                 "<oid>.10.<item_id> = STRING: <operability>"
        dns = {}
        operabilities = {}
        for line in res.stdout.splitlines():
            if " = " not in line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value = parts
            # Extract base part and instance
            if oid_full.startswith(base_oid + ".2."):
                item_id = oid_full[len(base_oid + ".2."):]
                dns[item_id] = value.strip().strip('"')
            elif oid_full.startswith(base_oid + ".10."):
                item_id = oid_full[len(base_oid + ".10."):]
                operabilities[item_id] = value.strip().strip('"')
        
        # Map item_id to fan name: " ".join(name.split("/")[2:])
        out = []
        for item_id, dn in dns.items():
            if item_id not in operabilities:
                continue
            parts = dn.split("/")
            if len(parts) < 3:
                item = dn
            else:
                item = " ".join(parts[2:])
            out.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # First, get the DN and operability for the specific fan
    base_oid = ".1.3.6.1.4.1.9.9.719.1.15.12.1"
    
    # Walk to find the right item
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    dns = {}
    operabilities = {}
    for line in res.stdout.splitlines():
        if " = " not in line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value = parts
        if oid_full.startswith(base_oid + ".2."):
            item_id = oid_full[len(base_oid + ".2."):]
            dns[item_id] = value.strip().strip('"')
        elif oid_full.startswith(base_oid + ".10."):
            item_id = oid_full[len(base_oid + ".10."):]
            operabilities[item_id] = value.strip().strip('"')
    
    # Find matching fan
    target_dn = ""
    for item_id, dn in dns.items():
        parts = dn.split("/")
        if len(parts) >= 3:
            fan_name = " ".join(parts[2:])
        else:
            fan_name = dn
        if fan_name == item:
            target_dn = dn
            break
    
    if not target_dn:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get operability value for this fan
    operability_str = operabilities.get(item_id, "")
    
    # Map operability to state
    MAP_OPERABILITY = {
        "0": (2, "unknown"),
        "1": (0, "operable"),
        "2": (2, "inoperable"),
        "3": (2, "degraded"),
        "4": (1, "poweredOff"),
        "5": (2, "powerProblem"),
        "6": (0, "removed"),
        "7": (2, "voltageProblem"),
        "8": (2, "thermalProblem"),
        "9": (1, "performanceProblem"),
        "10": (1, "accessibilityProblem"),
        "11": (1, "identityUnestablishable"),
        "12": (2, "biosPostTimeout"),
        "13": (1, "disabled"),
        "14": (1, "malformedFru"),
        "51": (1, "fabricConnProblem"),
        "52": (1, "fabricUnsupportedConn"),
        "81": (1, "config"),
        "82": (2, "equipmentProblem"),
        "83": (2, "decomissioning"),
        "84": (1, "chassisLimitExceeded"),
        "100": (1, "notSupported"),
        "101": (1, "discovery"),
        "102": (2, "discoveryFailed"),
        "103": (1, "identify"),
        "104": (2, "postFailure"),
        "105": (1, "upgradeProblem"),
        "106": (1, "peerCommProblem"),
        "107": (0, "autoUpgrade"),
        "108": (1, "linkActivateBlocked"),
    }
    
    # Map to state
    state_code = 0
    state_name = "unknown"
    if operability_str in MAP_OPERABILITY:
        state_code = MAP_OPERABILITY[operability_str][0]
        state_name = MAP_OPERABILITY[operability_str][1]
    
    # Convert state_code to Starlark State
    # 0 = OK, 1 = WARN, 2 = CRIT
    if state_code == 0:
        state = "OK"
    elif state_code == 1:
        state = "WARN"
    else:
        state = "CRIT"
    
    # Now fetch faults for this fan ID (dn)
    fault_base_oid = ".1.3.6.1.4.1.9.9.719.1.15.4.1"
    res_faults = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, fault_base_oid
    ], mutates=False)
    
    if res_faults.rc == 0:
        # Process faults
        faults = []
        for line in res_faults.stdout.splitlines():
            if " = " not in line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value = parts
            # cucsFaultDn = .1.3.6.1.4.1.9.9.719.1.15.4.1.2
            if oid_full.startswith(fault_base_oid + ".2."):
                item_id = oid_full[len(fault_base_oid + ".2."):]
                if dns.get(item_id, "") == target_dn:
                    # Found a fault for this fan - need more info
                    faults.append({
                        "dn": target_dn,
                        "item_id": item_id,
                        "oid_id": oid_full
                    })
        
        # For each fault found, get additional details (code, description, severity)
        fault_details = []
        for fault in faults:
            # Get faultCode (.1.3.6.1.4.1.9.9.719.1.15.4.1.4)
            oid_code = fault_base_oid + ".4." + fault["item_id"]
            # Get faultDescription (.1.3.6.1.4.1.9.9.719.1.15.4.1.5)
            oid_desc = fault_base_oid + ".5." + fault["item_id"]
            # Get faultSeverity (.1.3.6.1.4.1.9.9.719.1.15.4.1.6)
            oid_sev = fault_base_oid + ".6." + fault["item_id"]
            
            # Try to get each field via individual snmpget (simpler than parsing all)
            # But we'll just look for these OIDs in the previous walk output
            # We'll scan the original walk output again for these
            fault_code = ""
            fault_desc = ""
            fault_sev = ""
            
            for line in res_faults.stdout.splitlines():
                if " = " not in line:
                    continue
                parts = line.split(" = ")
                if len(parts) != 2:
                    continue
                oid_full, value = parts
                oid_base = oid_full.rsplit(".", 1)[0]
                if oid_base == fault["oid_id"].rsplit(".", 1)[0]:
                    suffix = oid_full[len(fault["oid_id"].rsplit(".", 1)[0] + "."):]
                    if suffix == "4":
                        fault_code = value.strip().strip('"')
                    elif suffix == "5":
                        fault_desc = value.strip().strip('"')
                    elif suffix == "6":
                        fault_sev = value.strip().strip('"')
            
            # Map severity
            sev_state = 0
            if fault_sev == "0":
                sev_state = 0  # cleared -> OK
            elif fault_sev == "1":
                sev_state = 0  # info -> OK
            elif fault_sev == "3":
                sev_state = 1  # warning -> WARN
            elif fault_sev == "4":
                sev_state = 1  # minor -> WARN
            elif fault_sev == "5":
                sev_state = 2  # major -> CRIT
            elif fault_sev == "6":
                sev_state = 2  # critical -> CRIT
            
            if sev_state == 0:
                sev_name = "OK"
            elif sev_state == 1:
                sev_name = "WARN"
            else:
                sev_name = "CRIT"
            
            # Collect fault data
            fault_details.append({
                "state": sev_name,
                "code": fault_code,
                "desc": fault_desc
            })
        
        # Build message and check for worst fault state
        if fault_details:
            worst_state = state
            fault_msgs = ""
            for f in fault_details:
                if f["state"] == "CRIT":
                    worst_state = "CRIT"
                elif f["state"] == "WARN" and worst_state != "CRIT":
                    worst_state = "WARN"
                fault_msgs += "Fault: %s - %s " % (f["code"], f["desc"])
            
            if worst_state == "OK":
                msg = "Status: %s, %s" % (state_name, "No faults")
            else:
                msg = "Status: %s, %s" % (state_name, fault_msgs.strip())
        else:
            msg = "Status: %s" % state_name
    else:
        # Fall back without faults
        msg = "Status: %s" % state_name
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
