def main(ctx, params):
    # Discover mode: enumerate DAG databases with a non-NotApplicable ContentIndexState
    if params.get("_discover"):
        res = ctx.run(["Get-MailboxDatabaseCopyStatus", "-StatusOnly"], mutates=False)
        lines = res.stdout.splitlines()
        
        items = []
        current_db = None
        content_index_state = None
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
            if ":" in line:
                parts = line.split(":", 1)
                if len(parts) == 2:
                    key = parts[0].strip()
                    val = parts[1].strip()
                    if key == "DatabaseName":
                        current_db = val
                        content_index_state = None
                    elif key == "ContentIndexState":
                        if current_db != None and val not in (None, "NotApplicable"):
                            content_index_state = val
        
        # We need to collect items while parsing; rewrite loop to handle correctly
        items = []
        current_db = None
        content_index_state = None
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
            if ":" in line:
                parts = line.split(":", 1)
                if len(parts) == 2:
                    key = parts[0].strip()
                    val = parts[1].strip()
                    if key == "DatabaseName":
                        current_db = val
                        content_index_state = None
                    elif key == "ContentIndexState" and current_db != None:
                        if val not in (None, "NotApplicable"):
                            content_index_state = val
                            items.append({"item": current_db, "params": {}, "metrics": []})
        
        return {
            "changed": False,
            "msg": "discovered %d content index entries" % len(items),
            "data": {"discovery": items},
        }
    
    # Check mode: verify one item's ContentIndexState
    item = params.get("item", "")
    res = ctx.run(["Get-MailboxDatabaseCopyStatus", "-StatusOnly"], mutates=False)
    lines = res.stdout.splitlines()
    
    content_index_state = None
    
    current_db = None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if ":" in line:
            parts = line.split(":", 1)
            if len(parts) == 2:
                key = parts[0].strip()
                val = parts[1].strip()
                if key == "DatabaseName":
                    current_db = val
                elif key == "ContentIndexState" and current_db == item:
                    content_index_state = val
                    break
    
    if content_index_state == None:
        return {
            "changed": False,
            "msg": "ContentIndexState not found for database " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    if content_index_state == "NotApplicable":
        return {
            "changed": False,
            "msg": "ContentIndex no longer available in recent Exchange versions. You can safely delete this Service.",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }
    
    state = "OK" if content_index_state == "Healthy" else "WARN"
    return {
        "changed": False,
        "msg": "Status: " + content_index_state,
        "data": {"state": state, "metrics": {}, "details": ""},
    }