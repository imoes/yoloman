def main(ctx, params):
    if params.get("_discover"):
        # Run the same data probe the Checkmk agent would run for msexch_dag
        # The Checkmk agent section is msexch_dag:sep(58) — parse colon-separated key: value lines
        res = ctx.run(["Get-MailboxDatabaseCopyStatus", "-StatusOnly"], mutates=False)
        lines = res.stdout.splitlines() if res.stdout else []
        databases = []
        current = {}
        start_key = ""
        for line in lines:
            line = line.strip()
            if not line:
                continue
            idx = line.find(":")
            if idx == -1:
                continue
            key = line[:idx].strip()
            val = line[idx+1:].strip()
            if not start_key:
                start_key = key
            if key == start_key:
                current = {}
            if key == "DatabaseName":
                databases.append(val)
            else:
                current[key] = val
        discovery = [{"item": db, "params": {"levels": [100, 200]}, "metrics": ["length"]} for db in databases]
        return {"changed": False, "msg": "discovered %d DAG databases" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode for one item
    item = params.get("item", "")
    levels = params.get("levels", [100, 200])
    warn, crit = int(levels[0]), int(levels[1])

    res = ctx.run(["Get-MailboxDatabaseCopyStatus", "-StatusOnly"], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []
    copy_queue = None
    current = {}
    start_key = ""
    for line in lines:
        line = line.strip()
        if not line:
            continue
        idx = line.find(":")
        if idx == -1:
            continue
        key = line[:idx].strip()
        val = line[idx+1:].strip()
        if not start_key:
            start_key = key
        if key == start_key:
            current = {}
        if key == "DatabaseName":
            if val == item:
                copy_queue = current.get("CopyQueueLength")
                break
        else:
            current[key] = val

    if copy_queue == None:
        return {"changed": False, "msg": "database %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val = int(copy_queue) if copy_queue.isdigit() else 0
    if val >= crit:
        state = "CRIT"
    elif val >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False, "msg": "Queue length: %d" % val,
            "data": {"state": state, "metrics": {"length": val}, "details": ""}}