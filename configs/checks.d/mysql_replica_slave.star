# Helper to convert numeric strings to int or bool/None
def _to_value(s):
    s = s.strip()
    if s.isdigit():
        return int(s)
    if s == "Yes":
        return True
    if s == "No":
        return False
    if s == "NULL" or s == "None":
        return None
    return s

def _parse_mysql_replica_slave(lines):
    # Return Error-like dict if first line looks like an error
    if len(lines) == 1 and len(lines[0]) == 1 and lines[0][0].startswith("ERROR "):
        return {"error": " ".join(lines[0])}
    result = {}
    for line in lines:
        if len(line) == 0:
            continue
        key = line[0]
        if not key.endswith(":"):
            continue
        key = key[:-1]  # strip trailing colon
        rest = " ".join(line[1:]) if len(line) > 1 else ""
        result[key] = _to_value(rest)
    return result

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Run mysql command to get replica status (same as Checkmk agent plugin does)
        res = ctx.run([
            "mysql",
            "-N",
            "-e",
            "SHOW SLAVE STATUS\\G; SHOW REPLICA STATUS\\G;"
        ], mutates=False)
        # If mysql not installed or fails, return empty discovery
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Parse output into sections per item
        sections = {}
        current_item = "mysql"
        current_lines = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            # Look for section headers like [[item]] or just detect SHOW commands
            if stripped.startswith("[[") and stripped.endswith("]]"):
                if current_lines:
                    sections[current_item] = current_lines
                current_item = stripped.strip("[] ")
                current_lines = []
                continue
            # If line looks like a SHOW command header, start new section
            if stripped.startswith("SHOW ") or stripped.startswith(" Slave ") or stripped.startswith(" Replica "):
                if current_lines:
                    sections[current_item] = current_lines
                current_item = "mysql"
                current_lines = []
                continue
            # Parse key: value lines (key ends with ':')
            if ":" in stripped and not stripped.startswith(""):
                parts = stripped.split(":", 1)
                if len(parts) == 2:
                    current_lines.append([parts[0].strip(), parts[1].strip()])
        if current_lines:
            sections[current_item] = current_lines
        
        # Parse sections
        parsed = {}
        for item, lines in sections.items():
            parsed[item] = _parse_mysql_replica_slave(lines)
        
        # Build discovery list (only include items with valid data)
        items = []
        for item, data in parsed.items():
            if data and (data.get("Slave_IO_Running") != None or data.get("Replica_IO_Running") != None):
                items.append({
                    "item": item,
                    "params": {"seconds_behind_master": ["no_levels", None]},
                    "metrics": ["relay_log_space", "sync_latency"]
                })
        
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "mysql")
    res = ctx.run([
        "mysql",
        "-N",
        "-e",
        "SHOW SLAVE STATUS\\G; SHOW REPLICA STATUS\\G;"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "unable to query MySQL replica status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output into sections
    sections = {}
    current_item = "mysql"
    current_lines = []
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("[[") and stripped.endswith("]]"):
            if current_lines:
                sections[current_item] = current_lines
            current_item = stripped.strip("[] ")
            current_lines = []
            continue
        if stripped.startswith("SHOW ") or stripped.startswith(" Slave ") or stripped.startswith(" Replica "):
            if current_lines:
                sections[current_item] = current_lines
            current_item = "mysql"
            current_lines = []
            continue
        if ":" in stripped:
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                current_lines.append([parts[0].strip(), parts[1].strip()])
    if current_lines:
        sections[current_item] = current_lines
    
    # Parse specific item section
    section_data = sections.get(item)
    if section_data == None or len(section_data) == 0:
        return {
            "changed": False,
            "msg": "no data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    data = _parse_mysql_replica_slave(section_data)
    
    # Handle error data
    if type(data) == "dict" and data.get("error") != None:
        return {
            "changed": False,
            "msg": data["error"],
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
    
    # Detect whether it's a replica or slave
    replica_or_slave = "Replica" if data.get("Replica_IO_Running") != None else "Slave"
    
    io_running = data.get(replica_or_slave + "_IO_Running")
    sql_running = data.get(replica_or_slave + "_SQL_Running")
    relay_log_space = data.get("Relay_Log_Space")
    seconds_field = "Seconds_Behind_Source" if replica_or_slave == "Replica" else "Seconds_Behind_Master"
    source_or_master = "source" if replica_or_slave == "Replica" else "master"
    sbm = data.get(seconds_field)
    
    summary_parts = []
    state = "OK"
    
    # Check IO thread
    if io_running == None:
        summary_parts.append(replica_or_slave + "-IO: unknown")
        state = "UNKNOWN"
    elif io_running == True:
        summary_parts.append(replica_or_slave + "-IO: running")
        # Relay log space (only if non-NULL)
        if relay_log_space != None and relay_log_space != "NULL":
            summary_parts.append("Relay log: " + str(relay_log_space))
    else:
        summary_parts.append(replica_or_slave + "-IO: not running")
        state = "CRIT"
    
    # Check SQL thread
    if sql_running == None:
        summary_parts.append(replica_or_slave + "-SQL: unknown")
        if state != "CRIT":
            state = "UNKNOWN"
    elif sql_running == False:
        summary_parts.append(replica_or_slave + "-SQL: not running")
        state = "CRIT"
        return {
            "changed": False,
            "msg": ", ".join(summary_parts),
            "data": {"state": state, "metrics": {}, "details": ""}
        }
    else:
        summary_parts.append(replica_or_slave + "-SQL: running")
    
    # Seconds behind source/master
    if sbm == None or sbm == "NULL":
        summary_parts.append("Time behind " + source_or_master + ": NULL (Lost connection?)")
        state = "CRIT"
        return {
            "changed": False,
            "msg": ", ".join(summary_parts),
            "data": {"state": state, "metrics": {}, "details": ""}
        }
    
    # Convert seconds_behind_master for levels check
    warn = None
    crit = None
    levels_config = params.get("seconds_behind_master", ["no_levels", None])
    if levels_config[0] == "fixed":
        warn = levels_config[1][0]
        crit = levels_config[1][1]
    
    # Determine state based on levels
    sbm_int = sbm
    if type(sbm_int) == "float":
        sbm_int = int(sbm_int)
    if type(sbm_int) == "int":
        if crit != None and sbm_int >= crit:
            state = "CRIT"
        elif warn != None and sbm_int >= warn:
            state = "WARN"
    else:
        state = "UNKNOWN"
    
    summary_parts.append("Time behind " + source_or_master + ": " + str(sbm) + "s")
    
    metrics = {}
    if type(sbm_int) == "int" and sbm_int >= 0:
        metrics["sync_latency"] = sbm_int
    
    # If relay_log_space is numeric, include it
    if type(relay_log_space) == "int":
        metrics["relay_log_space"] = relay_log_space
    
    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {"state": state, "metrics": metrics, "details": ""}
    }