# ===== check plugin: checkmk.netscaler_tcp_conns.star =====

# SNMP OIDs for Citrix NetScaler TCP connections
OID_TCP_CUR_SERVER_CONN = ".1.3.6.1.4.1.5951.4.1.1.46.1.0"
OID_TCP_CUR_CLIENT_CONN = ".1.3.6.1.4.1.5951.4.1.1.46.2.0"

# Checkmk defaults for thresholds
DEFAULT_SERVER_CONNS_LEVELS = (25000, 30000)
DEFAULT_CLIENT_CONNS_LEVELS = (25000, 30000)

def _snmp_get_value(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    if res.rc != 0:
        return None
    # Parse "OID = STRING: value" or similar format
    line = res.stdout.strip()
    # Extract the value after the last colon and space
    parts = line.rsplit(":", 1)
    if len(parts) < 2:
        return None
    value_str = parts[1].strip()
    # Handle quoted strings (e.g., "Counter32: 123")
    if value_str.startswith('"') and value_str.endswith('"'):
        value_str = value_str[1:-1]
    # Remove trailing whitespace and possible units
    value_str = value_str.split()[0] if value_str else ""
    return value_str

def _parse_snmp_data(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    server_conns_str = _snmp_get_value(ctx, community, host, OID_TCP_CUR_SERVER_CONN)
    client_conns_str = _snmp_get_value(ctx, community, host, OID_TCP_CUR_CLIENT_CONN)
    
    if server_conns_str == None or client_conns_str == None:
        return None
    
    # Convert to integers
    server_conns = int(server_conns_str) if server_conns_str.isdigit() else 0
    client_conns = int(client_conns_str) if client_conns_str.isdigit() else 0
    
    return {"server_conns": server_conns, "client_conns": client_conns}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: always yield one service
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["server_conns", "client_conns"]}]}
        }
    
    # Check mode for the single item
    section = _parse_snmp_data(ctx, params)
    
    if section == None:
        return {
            "changed": False,
            "msg": "unable to retrieve TCP connection data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    server_conns = section["server_conns"]
    client_conns = section["client_conns"]
    
    # Apply thresholds
    server_levels = params.get("server_conns", DEFAULT_SERVER_CONNS_LEVELS)
    client_levels = params.get("client_conns", DEFAULT_CLIENT_CONNS_LEVELS)
    
    # Default levels: (warn, crit)
    server_warn = server_levels[0] if len(server_levels) == 2 else None
    server_crit = server_levels[1] if len(server_levels) == 2 else None
    client_warn = client_levels[0] if len(client_levels) == 2 else None
    client_crit = client_levels[1] if len(client_levels) == 2 else None
    
    # Determine states
    state = "OK"
    details_parts = []
    metrics = {}
    
    # Server connections check
    if server_crit != None and server_conns >= server_crit:
        state = "CRIT"
        details_parts.append("server connections >= %d (critical at %d)" % (server_conns, server_crit))
    elif server_warn != None and server_conns >= server_warn:
        state = "WARN"
        details_parts.append("server connections >= %d (warning at %d)" % (server_conns, server_warn))
    else:
        details_parts.append("server connections: %d" % server_conns)
    metrics["server_conns"] = server_conns
    
    # Client connections check
    if client_crit != None and client_conns >= client_crit:
        state = "CRIT"
        details_parts.append("client connections >= %d (critical at %d)" % (client_conns, client_crit))
    elif client_warn != None and client_conns >= client_warn:
        state = "WARN"
        details_parts.append("client connections >= %d (warning at %d)" % (client_conns, client_warn))
    else:
        details_parts.append("client connections: %d" % client_conns)
    metrics["client_conns"] = client_conns
    
    return {
        "changed": False,
        "msg": "%s connections - %s" % (state.lower(), "; ".join(details_parts)),
        "data": {"state": state, "metrics": metrics, "details": "; ".join(details_parts)}
    }