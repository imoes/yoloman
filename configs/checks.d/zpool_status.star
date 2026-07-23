# Checkmk zpool_status check - read-only Starlark translation
# Discovery: one service per host (no items)
# Check: parse zpool status output, compute state from messages

def _parse_zpool_status(string_table):
    # Returns dict: {message, state_messages, pool_messages}
    if not string_table:
        return None
    
    first_line = " ".join(string_table[0])
    if first_line == "all pools are healthy":
        return {"message": "All pools are healthy"}
    
    if first_line == "no pools available":
        return {"message": "No pools available"}
    
    state_messages = []
    error_pools = {}  # name -> (state, health, read, write, cksum) etc.
    warning_pools = {} # same structure for devices with CKSUM errors
    pool_messages = {} # pool -> [messages]
    
    last_pool = ""
    start_pool = False
    multiline = False
    
    for line in string_table:
        if not line:
            continue
        token = line[0] if len(line) > 0 else ""
        
        if token == "pool:":
            last_pool = line[1] if len(line) > 1 else ""
            pool_messages.setdefault(last_pool, [])
        
        elif token == "state:":
            if len(line) > 1:
                state_messages.append(line[1])
        
        elif token in ["status:", "action:"]:
            if len(line) > 1:
                pool_messages[last_pool].append(" ".join(line[1:]))
            multiline = True
        
        elif token in ["scrub:", "see:", "scan:", "config:"]:
            multiline = False
        
        elif token == "NAME":
            multiline = False
            start_pool = True
        
        elif token == "errors:":
            multiline = False
            start_pool = False
            msg = " ".join(line[1:]) if len(line) > 1 else ""
            if msg != "No known data errors":
                pool_messages[last_pool].append(msg)
        
        elif token in ["spares", "logs", "cache", "special"]:
            start_pool = False
            continue
        
        elif start_pool and token and token.lower() != "dedup":
            # Expected format: NAME STATE HEALTH READ WRITE CKSUM ...
            # At least 2 fields required (name + state)
            if len(line) < 2:
                continue
            name = line[0]
            state = line[1]
            if state != "ONLINE":
                error_pools[name] = tuple(line)
            elif len(line) > 4:
                cksum_str = line[4] if len(line) > 4 else "0"
                # saveint equivalent: int() or 0 if non-digit
                cksum = 0
                if cksum_str.isdigit():
                    cksum = int(cksum_str)
                if cksum != 0:
                    warning_pools[name] = tuple(line)
        
        elif multiline and last_pool:
            # Append remaining tokens as message
            if len(line) > 0:
                pool_messages[last_pool].append(" ".join(line))
    
    return {
        "message": "",
        "state_messages": state_messages,
        "error_pools": error_pools,
        "warning_pools": warning_pools,
        "pool_messages": pool_messages,
    }

def _state_details(msg):
    mappings = {
        "ONLINE": {"state": "OK", "message": ""},
        "DEGRADED": {"state": "WARN", "message": "DEGRADED State"},
        "FAULTED": {"state": "CRIT", "message": "FAULTED State"},
        "UNAVIL": {"state": "CRIT", "message": "UNAVIL State"},
        "REMOVED": {"state": "CRIT", "message": "REMOVED State"},
        "OFFLINE": {"state": "OK", "message": ""},
    }
    return mappings.get(msg, {"state": "WARN", "message": "Unknown State"})

def main(ctx, params):
    # Probe data: run 'zpool status -x' to get compact status, or fallback to 'zpool status'
    # Prefer 'zpool status' to match original check's format; use -v for full output
    res = ctx.run(["zpool", "status", "-v"], mutates=False)
    if res.rc != 0:
        # zpool command not available or error
        return {
            "changed": False,
            "msg": "zpool command failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "zpool status failed with rc=%s, stderr=%s" % (res.rc, res.stderr)
            }
        }
    
    # Split lines preserving whitespace for accurate parsing
    lines = res.stdout.splitlines()
    string_table = []
    for line in lines:
        # Split by whitespace preserving fields
        fields = line.split()
        if fields:
            string_table.append(fields)
    
    section = _parse_zpool_status(string_table)
    
    # Discovery mode
    if params.get("_discover"):
        if section == None or section.get("message") == "No pools available":
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {},
                    "metrics": []
                }
            ]}
        }
    
    # Check mode: single-service (item == "")
    state = "OK"
    messages = []
    
    if section == None:
        state = "UNKNOWN"
        messages.append("No pools detected")
    elif section.get("message") == "All pools are healthy":
        state = "OK"
        messages.append(section["message"])
    elif section.get("message") == "No pools available":
        state = "UNKNOWN"
        messages.append("No pools available")
    else:
        # Process state messages
        for msg in section.get("state_messages", []):
            details = _state_details(msg)
            state = details["state"]
            if details["message"]:
                messages.append(details["message"])
        
        # Process pool-level messages
        for pool, msgs in section.get("pool_messages", {}).items():
            if state != "CRIT":  # only elevate if not already CRIT
                state = "WARN"
            for msg in msgs:
                messages.append("%s: %s" % (pool, msg))
        
        # Process warning pools (CKSUM errors)
        for pool, msg in section.get("warning_pools", {}).items():
            if state != "CRIT":
                state = "WARN"
            # msg[3] is CKSUM count per original code
            cksum = 0
            if len(msg) > 3 and msg[3].isdigit():
                cksum = int(msg[3])
            messages.append("%s CKSUM: %d" % (pool, cksum))
        
        # Process error pools
        for pool, msg in section.get("error_pools", {}).items():
            state = "CRIT"
            if len(msg) > 0:
                messages.append("%s state: %s" % (pool, msg[0]))
            else:
                messages.append("%s state: unknown" % pool)
    
    if len(messages) == 0:
        messages.append("No critical errors")
    
    # Build summary
    summary = ", ".join(messages)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
