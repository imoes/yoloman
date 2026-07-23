def main(ctx, params):
    # Read the agent section data directly from the host
    # The Checkmk plugin parses the "unitrends_replication" agent section
    # which is normally produced by a shell snippet that runs:
    #   /usr/bin/backup_exec_replication_status.sh --json 2>/dev/null
    # We replicate that behavior by calling the same script.
    
    res = ctx.run(["/usr/bin/backup_exec_replication_status.sh", "--json"], mutates=False)
    
    # If command fails or produces no output, report UNKNOWN
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "Unable to retrieve replication status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Guard before parsing JSON
    if not res.stdout:
        return {
            "changed": False,
            "msg": "No output from replication script",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse JSON output (no try/except possible, rely on agent providing valid JSON)
    data = json.decode(res.stdout)
    
    # Discovery mode
    if params.get("_discover"):
        targets = []
        seen = set()
        if type(data) == "list":
            for entry in data:
                if type(entry) == "list" and len(entry) >= 5:
                    target = entry[3]
                    if target not in seen:
                        seen.add(target)
                        targets.append({"item": target, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d targets" % len(targets),
            "data": {"discovery": targets}
        }
    
    # Check mode: process specific item
    item = params.get("item", "")
    
    # Filter entries for this item
    replications = []
    if type(data) == "list":
        for entry in data:
            if type(entry) == "list" and len(entry) >= 5 and entry[3] == item:
                replications.append(entry)
    
    # No entries found for this item
    if len(replications) == 0:
        return {
            "changed": False,
            "msg": "No Entries found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Find non-successful replications
    not_successful = []
    for x in replications:
        if len(x) >= 2 and x[1] != "Success":
            not_successful.append(x)
    
    if len(not_successful) == 0:
        return {
            "changed": False,
            "msg": "All Replications in the last 24 hours Successfull",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }
    
    # Build error messages
    messages = []
    for entry in not_successful:
        target = entry[3] if len(entry) >= 4 else ""
        result = entry[1] if len(entry) >= 2 else ""
        instance = entry[4] if len(entry) >= 5 else ""
        messages.append("Target: %s, Result: %s, Instance: %s" % (target, result, instance))
    
    # Return critical state with error details
    return {
        "changed": False,
        "msg": "Errors from the last 24 hours: " + "/ ".join(messages),
        "data": {"state": "CRIT", "metrics": {}, "details": ""}
    }