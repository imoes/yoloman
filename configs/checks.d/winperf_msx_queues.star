def main(ctx, params):
    # Read the raw agent section data from the Windows perf counter
    # The Checkmk plugin reads <<<winperf_msx_queues>>>; we run the equivalent command
    # We use typeperf to read the same perfmon counters the plugin uses
    res = ctx.run(["typeperf", "-sc", "1", "\\MSExchangeTransport Queues(*)\\Messages in the Mailbox database queue", "\\MSExchangeTransport Queues(*)\\Messages in the Remote Delivery queue", "\\MSExchangeTransport Queues(*)\\Messages in the Retry Remote Delivery queue", "\\MSExchangeTransport Queues(*)\\Messages in the Active Mailbox Delivery queue", "\\MSExchangeTransport Queues(*)\\Messages in the Poison queue"], mutates=False)
    
    # Parse typeperf output: first line is headers in quotes, second line is values
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "no data from typeperf",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract values (strip quotes, split by comma)
    values = []
    tokens = lines[1].split(",")
    for token in tokens:
        token = token.strip().strip('"')
        if token and token != "System":
            # Guard instead of try/except: check if token is numeric-like before converting
            cleaned = token.replace(".", "", 1)
            if cleaned.isdigit() or (cleaned.startswith("-") and cleaned[1:].isdigit()):
                # Convert to float then int to handle decimals
                float_val = float(token)
                values.append(int(float_val))
            else:
                return {"changed": False, "msg": "invalid data format",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Map indices to queue names per Checkmk defaults (offsets from source)
    queue_map = [
        ("Active Remote Delivery", 2),
        ("Retry Remote Delivery", 4),
        ("Active Mailbox Delivery", 6),
        ("Poison Queue Length", 44),
    ]
    
    if params.get("_discover"):
        discovered = []
        for name, idx in queue_map:
            if idx - 1 < len(values):  # 0-based index vs 1-based offset
                discovered.append({"item": name, "params": {"offset": idx},
                                   "metrics": ["queue_length"]})
        return {"changed": False, "msg": "discovered %d queues" % len(discovered),
                "data": {"discovery": discovered}}
    
    # Check mode
    item = params.get("item", "")
    offset = params.get("offset")
    
    # Find queue name in map
    matched = False
    for name, off in queue_map:
        if name == item and off == offset:
            matched = True
            break
    
    if not matched or offset == None or offset - 1 >= len(values):
        return {"changed": False, "msg": "queue not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    length = values[offset - 1]  # convert 1-based offset to 0-based index
    
    # Apply levels
    warn, crit = params.get("levels", (500, 2000))
    state = "CRIT" if length >= crit else ("WARN" if length >= warn else "OK")
    
    return {"changed": False, "msg": "Length: %d" % length,
            "data": {"state": state, "metrics": {"queue_length": length}, "details": ""}}