# Top-level constants
OID_BASE = ".1.3.6.1.4.1.4547.2.3.3.2.1"
SNMP_VERSION = "2c"
SNMP_COMMUNITY = "public"

def _parse_snmp_output(lines):
    entries = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0]
        value_part = parts[1]
        
        # Extract last component (port index) from OID
        oid_tokens = oid_part.split(".")
        if len(oid_tokens) < 2:
            continue
        port_index = oid_tokens[-1]
        
        # Extract integer value
        value_str = value_part.split(": ", 1)[-1] if ": " in value_part else ""
        # Guard before conversion: check if digit
        value = 0
        if value_str.isdigit():
            value = int(value_str)
        else:
            # Skip non-numeric values
            continue
        
        # Find last OID component to distinguish tx (.2) vs rx (.3)
        last_dot_idx = oid_part.rfind(".")
        if last_dot_idx == -1:
            continue
        last_oid_component = oid_part[last_dot_idx+1:]
        
        # Initialize port entry if needed
        if port_index not in entries:
            entries[port_index] = {"tx": None, "rx": None}
        
        # Last component is 2 or 3
        if last_oid_component == "2":
            entries[port_index]["tx"] = value
        elif last_oid_component == "3":
            entries[port_index]["rx"] = value
    
    return entries

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", SNMP_COMMUNITY)
        
        # Walk the base OID
        res = ctx.run(["snmpwalk", "-v", SNMP_VERSION, "-c", community, "-On", host, OID_BASE], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to gather SNMP data", "data": {"discovery": []}}
        
        entries = _parse_snmp_output(res.stdout.splitlines())
        
        discovery_items = []
        for port_index, rates in entries.items():
            if rates["tx"] != None and rates["rx"] != None:
                discovery_items.append({
                    "item": str(port_index),
                    "params": {"fc_tx_words": None, "fc_rx_words": None},
                    "metrics": ["fc_tx_words", "fc_rx_words"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d ports" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", SNMP_COMMUNITY)
    
    res = ctx.run(["snmpwalk", "-v", SNMP_VERSION, "-c", community, "-On", host, OID_BASE], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to gather SNMP data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    entries = _parse_snmp_output(res.stdout.splitlines())
    
    if item not in entries:
        return {
            "changed": False,
            "msg": "port %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    rates = entries[item]
    tx_words_raw = rates.get("tx")
    rx_words_raw = rates.get("rx")
    
    if tx_words_raw == None or rx_words_raw == None:
        return {
            "changed": False,
            "msg": "no data for port %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    fc_tx_words = float(tx_words_raw)
    fc_rx_words = float(rx_words_raw)
    
    # Apply thresholds
    warn_tx = params.get("fc_tx_words", None)
    warn_rx = params.get("fc_rx_words", None)
    
    state = "OK"
    
    # TX
    if warn_tx != None:
        if fc_tx_words >= warn_tx:
            state = "CRIT"
    
    # RX
    if warn_rx != None:
        if fc_rx_words >= warn_rx:
            state = "CRIT"
        elif state == "OK" and warn_rx != None:
            state = "WARN"
    
    details_parts = []
    details_parts.append("TX: %f words/s" % fc_tx_words)
    details_parts.append("RX: %f words/s" % fc_rx_words)
    
    msg = ", ".join(details_parts)
    metrics = {"fc_tx_words": fc_tx_words, "fc_rx_words": fc_rx_words}
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
