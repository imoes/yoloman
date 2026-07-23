# Constants
SNMP_OID_BASE_MCAFEE = ".1.3.6.1.4.1.1230.2.7.2.1"
SNMP_OID_BASE_SKYHIGH = ".1.3.6.1.4.1.59732.2.7.2.1"
OID_INFECTIONS = "2"
OID_CONNECTIONS_BLOCKED = "5"

def _snmp_get(ctx, host, community, base_oid, oid_suffix):
    full_oid = base_oid + "." + oid_suffix
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, full_oid
    ], mutates=False)
    if res.rc != 0:
        return None
    line = res.stdout.strip()
    if not line:
        return None
    parts = line.split(" = ")
    if len(parts) < 2:
        return None
    value_str = parts[1].strip()
    # Handle different types: Gauge32, Counter32, Integer32, etc.
    # Typically looks like: "Gauge32: 0" or "INTEGER: 123"
    colon_idx = value_str.find(":")
    if colon_idx != -1:
        value_str = value_str[colon_idx+1:].strip()
    # Remove trailing spaces and quotes
    value_str = value_str.strip().strip('"')
    if value_str.isdigit():
        return int(value_str)
    return None

def _parse_value_store(value_store_str):
    # Parse JSON-encoded value store dict
    if not value_store_str:
        return {}
    d = json.decode(value_store_str)
    return d

def _encode_value_store(value_store):
    # Encode value store to JSON string
    s = json.encode(value_store)
    return s

def main(ctx, params):
    # Check if discover mode
    if params.get("_discover") == True:
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [{
                    "item": "",
                    "params": {},
                    "metrics": ["infections_rate", "connections_blocked_rate"]
                }]
            }
        }
    
    # Get parameters with defaults
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Try both base OIDs
    infections = _snmp_get(ctx, host, community, SNMP_OID_BASE_MCAFEE, OID_INFECTIONS)
    if infections == None:
        infections = _snmp_get(ctx, host, community, SNMP_OID_BASE_SKYHIGH, OID_INFECTIONS)
    
    connections_blocked = _snmp_get(ctx, host, community, SNMP_OID_BASE_MCAFEE, OID_CONNECTIONS_BLOCKED)
    if connections_blocked == None:
        connections_blocked = _snmp_get(ctx, host, community, SNMP_OID_BASE_SKYHIGH, OID_CONNECTIONS_BLOCKED)
    
    # Parse current value store from context (simulated via ctx.facts for this check)
    # Note: In real agent, value_store persists between invocations
    # Since Starlark has no persistence, we simulate using a context variable
    value_store_str = ctx.facts().get("_value_store", "{}")
    value_store = _parse_value_store(value_store_str)
    
    # Compute rates
    # Infections rate
    prev_infections = value_store.get("infections.prev")
    time_infections = value_store.get("infections.time")
    current_time = int(ctx.facts().get("timestamp", 0))
    
    infections_rate = None
    if infections != None:
        if prev_infections != None and time_infections != None:
            delta = infections - prev_infections
            time_delta = current_time - time_infections
            if time_delta > 0:
                infections_rate = float(delta) / float(time_delta)
        value_store["infections.prev"] = infections
        value_store["infections.time"] = current_time
    
    # Connections blocked rate
    prev_connections = value_store.get("connections_blocked.prev")
    time_connections = value_store.get("connections_blocked.time")
    
    connections_blocked_rate = None
    if connections_blocked != None:
        if prev_connections != None and time_connections != None:
            delta = connections_blocked - prev_connections
            time_delta = current_time - time_connections
            if time_delta > 0:
                connections_blocked_rate = float(delta) / float(time_delta)
        value_store["connections_blocked.prev"] = connections_blocked
        value_store["connections_blocked.time"] = current_time
    
    # Encode value store back
    new_value_store_str = _encode_value_store(value_store)
    
    # Determine state
    state = "OK"
    details_parts = []
    
    # Infections rate
    if infections == None:
        state = "UNKNOWN"
        details_parts.append("Infections: n/a")
    else:
        if infections_rate == None:
            details_parts.append("Infections: n/a (first run)")
        else:
            details_parts.append("Infections rate: %f/s" % infections_rate)
    
    # Connections blocked rate
    if connections_blocked == None:
        state = "UNKNOWN"
        details_parts.append("Connections blocked: n/a")
    else:
        if connections_blocked_rate == None:
            details_parts.append("Connections blocked: n/a (first run)")
        else:
            details_parts.append("Connections blocked rate: %f/s" % connections_blocked_rate)
    
    # Build metrics dict
    metrics = {}
    if infections_rate != None:
        metrics["infections_rate"] = infections_rate
    if connections_blocked_rate != None:
        metrics["connections_blocked_rate"] = connections_blocked_rate
    
    return {
        "changed": False,
        "msg": "; ".join(details_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }