def main(ctx, params):
    if params.get("_discover"):
        # Discovery: run the same data source the Checkmk agent would use
        res = ctx.run(["Get-MailboxDatabaseCopyStatus", "-Identity", "*"], mutates=False)
        # Parse the raw agent output manually: key: value pairs, blank lines separate records
        records = []
        current = {}
        start_key = None
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                if current:
                    records.append(current)
                    current = {}
                continue
            idx = line.find(":")
            if idx == -1:
                continue
            key = line[:idx].strip()
            val = line[idx+1:].strip()
            if not start_key:
                start_key = key
            if key == start_key and current:
                records.append(current)
                current = {}
            if key == "DatabaseName":
                current[key] = val
                records.append(current)
                current = {}
            else:
                current[key] = val
        if current:
            records.append(current)

        # Group records by DatabaseName
        db_map = {}
        for rec in records:
            dbname = rec.get("DatabaseName")
            if dbname:
                db_map[dbname] = rec

        items = []
        status_key = "Status"
        for dbname, db in db_map.items():
            status = db.get(status_key)
            if status != None:
                items.append({
                    "item": dbname,
                    "params": {"inv_key": status_key, "inv_val": status},
                    "metrics": []
                })
        return {"changed": False, "msg": "discovered %d database copies" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    inv_key = params.get("inv_key", "Status")
    inv_val = params.get("inv_val", "")

    res = ctx.run(["Get-MailboxDatabaseCopyStatus", "-Identity", "*"], mutates=False)
    # Parse the raw agent output manually
    records = []
    current = {}
    start_key = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            if current:
                records.append(current)
                current = {}
            continue
        idx = line.find(":")
        if idx == -1:
            continue
        key = line[:idx].strip()
        val = line[idx+1:].strip()
        if not start_key:
            start_key = key
        if key == start_key and current:
            records.append(current)
            current = {}
        if key == "DatabaseName":
            current[key] = val
            records.append(current)
            current = {}
        else:
            current[key] = val
    if current:
        records.append(current)

    db_map = {}
    for rec in records:
        dbname = rec.get("DatabaseName")
        if dbname:
            db_map[dbname] = rec

    db = db_map.get(item, {})
    current_val = db.get(inv_key)

    if current_val == None:
        return {"changed": False, "msg": "no such database copy: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if current_val == inv_val:
        state = "OK"
    else:
        state = "WARN"

    return {"changed": False,
            "msg": "%s is %s" % (inv_key, current_val),
            "data": {"state": state, "metrics": {}, "details": ""}}