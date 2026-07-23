def main(ctx, params):
    # SNMP base OID for fortimail_queue section
    base_oid = ".1.3.6.1.4.1.12356.105.1.103.2.1"
    
    # Discovery mode: enumerate all queue items
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid + ".2"  # fmlMailQueueName
        ], mutates=False)
        
        # Build list of queue names from the walk output
        queue_names = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Format: OID = STRING: "queue name"
            idx = line.find('"')
            if idx >= 0:
                # Extract the string value between quotes
                value = line[idx+1:]
                end = value.find('"')
                if end > 0:
                    queue_name = value[:end]
                    queue_names.append(queue_name)
        
        # Return discovery results with suggested params (from check_default_parameters)
        discovery = []
        for name in queue_names:
            discovery.append({
                "item": name,
                "params": {"queue_length": (100, 200)},
                "metrics": ["mail_queue_active_length", "mail_queue_active_size"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d queues" % len(queue_names),
            "data": {"discovery": discovery}
        }
    
    # Check mode: verify one item
    item = params.get("item", "")
    if item == None:
        item = ""
    
    # Fetch all three OID columns (name, count, size) in one go
    # We'll use snmpwalk on the base OID and parse all entries together
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base_oid
    ], mutates=False)
    
    # Parse the output: group by queue index
    # OIDs look like: .1.3.6.1.4.1.12356.105.1.103.2.1.2.1 = "queue name"
    #                                               .3.1 = INTEGER: 31
    #                                               .4.1 = INTEGER: 534
    queues = {}
    current_index = ""
    name = ""
    count = ""
    size = ""
    
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        
        parts = line.split()
        if len(parts) < 2:
            continue
        
        oid_full = parts[0]
        # Extract the index: the last numeric component after base OID
        # e.g. .1.3.6.1.4.1.12356.105.1.103.2.1.2.1 -> index 1, OID suffix .2.1
        # Find position of base_oid and extract index part
        suffix = oid_full[len(base_oid):]
        if not suffix.startswith("."):
            continue
        suffix = suffix[1:]  # strip leading dot
        
        # Split suffix: type.index (e.g., "2.1", "3.1", "4.1")
        idx_dot = suffix.find(".")
        if idx_dot < 0:
            continue
        
        oid_type = int(suffix[:idx_dot])
        idx = int(suffix[idx_dot+1:])
        
        # Extract value (everything after the type string)
        # Format: OID = STRING: "..." / INTEGER: N / GAUGE: N
        value_part = "=".join(parts[1:]).strip()
        
        # Determine value
        val = ""
        if value_part.startswith('"'):
            # STRING type: extract quoted string
            end_quote = value_part.find('"', 1)
            if end_quote > 0:
                val = value_part[1:end_quote]
        else:
            # INTEGER/GAUGE: take numeric part
            if value_part.startswith("INTEGER:"):
                val = value_part[8:].strip()
            elif value_part.startswith("Gauge:"):
                val = value_part[6:].strip()
            elif value_part.startswith("INTEGER:"):
                val = value_part[8:].strip()
        
        # Store value in queues dict
        if idx != current_index:
            # New queue entry: finalize previous if exists
            if current_index != "" and name != "" and count != "" and size != "":
                queues[current_index] = {
                    "name": name,
                    "length": int(count) if count.isdigit() else 0,
                    "size": int(size) * 1024 if size.isdigit() else 0
                }
            current_index = str(idx)
            name = ""
            count = ""
            size = ""
        
        # Update current record based on OID type
        if oid_type == 2:
            name = val
        elif oid_type == 3:
            count = val
        elif oid_type == 4:
            size = val
    
    # Finalize last queue
    if current_index != "" and name != "" and count != "" and size != "":
        queues[current_index] = {
            "name": name,
            "length": int(count) if count.isdigit() else 0,
            "size": int(size) * 1024 if size.isdigit() else 0
        }
    
    # Find the queue matching the item
    queue_data = None
    for q in queues.values():
        if q["name"] == item:
            queue_data = {"length": q["length"], "size": q["size"]}
            break
    
    # If item not found, return UNKNOWN
    if queue_data == None:
        return {
            "changed": False,
            "msg": "queue not found: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Extract thresholds from params (default from check_default_parameters)
    warn_len = 100
    crit_len = 200
    if "queue_length" in params:
        levels = params["queue_length"]
        if levels != None and type(levels) == "list":
            warn_len = float(levels[0])
            crit_len = float(levels[1])
    
    # Compute state based on queue length (upper levels)
    length = queue_data["length"]
    if length >= crit_len:
        state = "CRIT"
    elif length >= warn_len:
        state = "WARN"
    else:
        state = "OK"
    
    # Format message
    return {
        "changed": False,
        "msg": "Length: %d, Size: %d" % (length, queue_data["size"]),
        "data": {
            "state": state,
            "metrics": {
                "mail_queue_active_length": length,
                "mail_queue_active_size": queue_data["size"]
            },
            "details": ""
        }
    }
