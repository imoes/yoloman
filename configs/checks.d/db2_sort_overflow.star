def main(ctx, params):
    if params.get("_discover"):
        # Discover DB2 databases by listing the DB2 directory
        res = ctx.run(["db2", "list", "db", "directory"], mutates=False)
        dbs = []
        for line in res.stdout.splitlines():
            if line.strip().startswith("Database name"):
                db_name = line.split()[-1]
                if db_name:
                    dbs.append(db_name)
        
        # For each database, try to get sort overflow data
        items = []
        for db in dbs:
            # Try to get sort data via db2pd
            res = ctx.run(["db2pd", "-d", db, "-sort"], mutates=False)
            if res.rc == 0:
                total_sorts = 0
                sort_overflows = 0
                for line in res.stdout.splitlines():
                    if "Total sorts" in line:
                        parts = line.split()
                        for p in parts:
                            if p.isdigit():
                                total_sorts = int(p)
                                break
                    if "Sort overflows" in line:
                        parts = line.split()
                        for p in parts:
                            if p.isdigit():
                                sort_overflows = int(p)
                                break
                # Only add if we found valid data
                if total_sorts > 0 or sort_overflows >= 0:
                    items.append({"item": db, "params": {"levels_perc": [2.0, 4.0]},
                                  "metrics": ["sort_overflow"]})
        
        return {"changed": False, "msg": "discovered %d DB2 databases" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    levels = params.get("levels_perc", [2.0, 4.0])
    warn = levels[0]
    crit = levels[1]
    
    # Get sort data for the specific database
    res = ctx.run(["db2pd", "-d", item, "-sort"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Failed to get data for database " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    total_sorts = 0
    sort_overflows = 0
    found_total = False
    found_overflow = False
    
    for line in res.stdout.splitlines():
        if found_total and found_overflow:
            break
        if "Total sorts" in line and not found_total:
            parts = line.split()
            for p in parts:
                if p.isdigit():
                    total_sorts = int(p)
                    found_total = True
                    break
        if "Sort overflows" in line and not found_overflow:
            parts = line.split()
            for p in parts:
                if p.isdigit():
                    sort_overflows = int(p)
                    found_overflow = True
                    break
    
    if total_sorts > 0:
        overflow_perc = sort_overflows * 100.0 / total_sorts
    else:
        overflow_perc = 0.0
    
    if overflow_perc >= crit:
        state = "CRIT"
        summary = "%f%% sort overflow (levels at %f%%/%f%%)" % (overflow_perc, warn, crit)
    elif overflow_perc >= warn:
        state = "WARN"
        summary = "%f%% sort overflow (levels at %f%%/%f%%)" % (overflow_perc, warn, crit)
    else:
        state = "OK"
        summary = "%f%% sort overflow" % overflow_perc
    
    return {"changed": False,
            "msg": "%s, Sort overflows: %d, Total sorts: %d" % (summary, int(sort_overflows), int(total_sorts)),
            "data": {"state": state, "metrics": {"sort_overflow": overflow_perc}, "details": ""}}