# ===== Starlark translation of Checkmk docsis_cm_status check =====
# SNMP OIDs for the cable modem status section
_BASE_OID = ".1.3.6.1.2.1.10.127.1.2.2.1"
_OID_STATUS = _BASE_OID + ".1"   # docsIfCmStatusCode
_OID_TX_POWER = _BASE_OID + ".3" # docsIfCmStatusTxPower

# Status table mapping (int -> string)
_STATUS_TABLE = {
    1: "other",
    2: "not ready",
    3: "not synchronized",
    4: "PHY synchronized",
    5: "upstream parameters acquired",
    6: "ranging complete",
    7: "IP complete",
    8: "TOD established",
    9: "security established",
    10: "params transfer complete",
    11: "registration complete",
    12: "operational",
    13: "access denied",
}

def _parse_snmpwalk(lines):
    """Parse snmpwalk output with OID values."""
    entries = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        # Format: OID = TYPE: value
        eq_pos = line.find("=")
        if eq_pos == -1:
            continue
        oid_part = line[:eq_pos].strip()
        val_part = line[eq_pos+1:].strip()
        
        # Extract OID end (last segment)
        last_dot = oid_part.rfind(".")
        if last_dot == -1:
            continue
        sid = oid_part[last_dot+1:].strip()
        # Extract value after type (e.g., "INTEGER: 4" -> "4")
        colon_pos = val_part.find(":")
        if colon_pos == -1:
            continue
        val_str = val_part[colon_pos+1:].strip()
        
        # Guard for numeric parsing
        val = 0
        if val_str.lstrip("-").isdigit():
            val = int(val_str)
        elif val_str.find(".") != -1:
            # Simple float check without try/except
            val = float(val_str) if val_str.replace(".", "", 1).lstrip("-").isdigit() else 0
        else:
            continue
        
        if sid not in entries:
            entries[sid] = {}
        
        # Determine which field by looking at original OID
        base_oid_part = oid_part[:last_dot]
        if base_oid_part == _OID_STATUS:
            entries[sid]["status"] = val
        elif base_oid_part == _OID_TX_POWER:
            entries[sid]["tx_power"] = val
    
    # Build list of (sid, status, tx_power)
    result = []
    for sid in sorted(entries.keys()):
        e = entries[sid]
        if "status" in e and "tx_power" in e:
            result.append((sid, e["status"], e["tx_power"]))
    return result

def _discover_modems(ctx, community, host):
    # Try to walk the status table
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        _BASE_OID + ".1",  # status
        _BASE_OID + ".3",  # tx_power
    ], mutates=False)
    
    if res.rc != 0:
        return []
    
    lines = res.stdout.splitlines()
    if not lines:
        return []
    
    return _parse_snmpwalk(lines)

def main(ctx, params):
    # Get connection params with defaults
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Default thresholds from Checkmk
    warn_tx = params.get("tx_power", [20.0, 10.0])[0]
    crit_tx = params.get("tx_power", [20.0, 10.0])[1]
    error_states = params.get("error_states", [13, 2, 1])
    
    if params.get("_discover"):
        # DISCOVERY MODE: list all modems found
        modems = _discover_modems(ctx, community, host)
        items = []
        for sid, status, tx_power in modems:
            items.append({
                "item": sid,
                "params": {"tx_power": [warn_tx, crit_tx], "error_states": error_states},
                "metrics": ["tx_power"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d modems" % len(items),
            "data": {"discovery": items}
        }
    
    # CHECK MODE: check specific item
    item = params.get("item", "")
    if item == "":
        # Default to first modem if none specified
        modems = _discover_modems(ctx, community, host)
        if len(modems) > 0:
            item = modems[0][0]
        else:
            return {
                "changed": False,
                "msg": "no modems found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
    
    # Find the requested modem
    modems = _discover_modems(ctx, community, host)
    found = False
    for sid, status, tx_power in modems:
        if sid == item:
            found = True
            # Status processing
            status_str = _STATUS_TABLE.get(status, "unknown (%d)" % status)
            infotext = "Status: %s" % status_str
            state = "CRIT" if status in error_states else "OK"
            
            # TX Power processing
            tx_power_dbmv = tx_power / 10.0
            levels_txt = " (warn/crit at %f/%f dBmV)" % (warn_tx, crit_tx)
            tx_state = "OK"
            tx_infotext = "TX Power is %f dBmV" % tx_power_dbmv
            if tx_power_dbmv <= crit_tx:
                tx_state = "CRIT"
                tx_infotext += levels_txt
            elif tx_power_dbmv <= warn_tx:
                tx_state = "WARN"
                tx_infotext += levels_txt
            
            # Determine final state (worst of status and tx_power)
            final_state = state
            if tx_state == "CRIT" or state == "CRIT":
                final_state = "CRIT"
            elif tx_state == "WARN" or state == "WARN":
                final_state = "WARN"
            
            return {
                "changed": False,
                "msg": "%s; %s" % (infotext, tx_infotext),
                "data": {
                    "state": final_state,
                    "metrics": {"tx_power": tx_power_dbmv},
                    "details": ""
                }
            }
    
    if not found:
        return {
            "changed": False,
            "msg": "Status Entry not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }