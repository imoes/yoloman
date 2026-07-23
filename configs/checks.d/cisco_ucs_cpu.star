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

MAP_PRESENCE = {
    "0": (1, "unknown"),
    "1": (0, "empty"),
    "10": (0, "equipped"),
    "11": (0, "missing"),
    "12": (1, "mismatch"),
    "13": (0, "equippedNotPrimary"),
    "14": (0, "equippedSlave"),
    "15": (1, "mismatchSlave"),
    "16": (1, "missingSlave"),
    "20": (1, "equippedIdentityUnestablishable"),
    "21": (1, "mismatchIdentityUnestablishable"),
}

def _parse_snmp_line(line):
    # Parse "OID = TYPE: value" lines
    idx = line.find("=")
    if idx == -1:
        return None, None
    oid_part = line[:idx].strip()
    value_part = line[idx+1:].strip()
    if ": " in value_part:
        value = value_part.split(": ", 1)[1]
    else:
        value = value_part
    # Strip trailing spaces/quotes
    value = value.strip().strip('"')
    return oid_part, value

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk the SNMP tree for cisco_ucs_cpu
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.9.9.719.1.41.9.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        
        # Parse the output: extract columns in order:
        # 3: cucsProcessorUnitRn (item name)
        # 13: cucsProcessorUnitPresence
        # 15: cucsProcessorUnitSerial
        # 8: cucsProcessorUnitModel
        # 10: cucsProcessorUnitOperability
        entries = []
        rn_map = {}
        presence_map = {}
        serial_map = {}
        model_map = {}
        status_map = {}
        
        lines = res.stdout.splitlines()
        for line in lines:
            oid, value = _parse_snmp_line(line)
            if oid == None or value == None:
                continue
            base_oid = oid.rsplit(".", 1)[-1]
            if base_oid == "3":
                rn_map[oid] = value
            elif base_oid == "13":
                presence_map[oid] = value
            elif base_oid == "15":
                serial_map[oid] = value
            elif base_oid == "8":
                model_map[oid] = value
            elif base_oid == "10":
                status_map[oid] = value
        
        # Build entries by matching RNs to their OIDs
        for rn_oid, rn in rn_map.items():
            if rn == "":
                continue
            presence = presence_map.get(rn_oid + ".13", "")
            serial = serial_map.get(rn_oid + ".15", "")
            model = model_map.get(rn_oid + ".8", "")
            status = status_map.get(rn_oid + ".10", "")
            # Only discover if presence != "11" (missing)
            if presence != "11":
                entries.append({
                    "item": rn,
                    "params": {},
                    "metrics": []
                })
        
        return {"changed": False, "msg": "discovered %d CPUs" % len(entries),
                "data": {"discovery": entries}}
    
    # Check mode: single item
    item = params.get("item", "")
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.9.9.719.1.41.9.1.3." + item,
        ".1.3.6.1.4.1.9.9.719.1.41.9.1.13." + item,
        ".1.3.6.1.4.1.9.9.719.1.41.9.1.15." + item,
        ".1.3.6.1.4.1.9.9.719.1.41.9.1.8." + item,
        ".1.3.6.1.4.1.9.9.719.1.41.9.1.10." + item
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP get failed for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    if len(lines) < 5:
        return {"changed": False, "msg": "missing SNMP data for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract values: line order corresponds to the OID order above
    _, presence_val = _parse_snmp_line(lines[1])
    _, serial_val = _parse_snmp_line(lines[2])
    _, model_val = _parse_snmp_line(lines[3])
    _, status_val = _parse_snmp_line(lines[4])
    
    # Use the parsed value, strip whitespace
    presence_val = presence_val.strip() if presence_val != None else ""
    serial_val = serial_val.strip() if serial_val != None else ""
    model_val = model_val.strip() if model_val != None else ""
    status_val = status_val.strip() if status_val != None else ""
    
    oper_state, oper_text = MAP_OPERABILITY.get(status_val, (3, "Unknown, status code %s" % status_val))
    pres_state, pres_text = MAP_PRESENCE.get(presence_val, (3, "Unknown, status code %s" % presence_val))
    
    # Determine overall state (worst of status/presence)
    state = "OK"
    if oper_state == 2 or pres_state == 2:
        state = "CRIT"
    elif oper_state == 1 or pres_state == 1:
        state = "WARN"
    
    summary = "Status: %s, Presence: %s" % (oper_text, pres_text)
    if model_val != "" or serial_val != "":
        summary = summary + ", Model: %s, SN: %s" % (model_val, serial_val)
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}
