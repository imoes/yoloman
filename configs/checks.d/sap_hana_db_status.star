def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["which", "hdbsql"], mutates=False)
        if res.rc != 0 or res.skipped:
            return {"changed": False, "msg": "discovery: no SAP HANA found", "data": {"discovery": []}}
        
        hdb_client = ctx.run(["hdbsql", "-v"], mutates=False)
        if hdb_client.rc != 0 and res.rc == 127:
            return {"changed": False, "msg": "no SAP HANA found", "data": {"discovery": []}}
        
        proc_res = ctx.run(["ls", "/usr/sap"], mutates=False)
        if proc_res.rc != 0:
            return {"changed": False, "msg": "no SAP HANA installations found", "data": {"discovery": []}}
        
        out = []
        sids = []
        for line in proc_res.stdout.splitlines():
            stripped = line.strip()
            if len(stripped) == 3 and stripped.isupper() and stripped != "tmp" and stripped != "data":
                sids.append(stripped)
        
        for sid in sids:
            inst_res = ctx.run(["ls", "/usr/sap/" + sid], mutates=False)
            if inst_res.rc != 0:
                continue
            for line in inst_res.stdout.splitlines():
                inst_name = line.strip()
                if inst_name.startswith("HDB") or inst_name.startswith("SR") or inst_name[0:1].isdigit():
                    item = sid.lower() + " - " + sid + "HDB" + inst_name
                    out.append({"item": item, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d SAP HANA databases" % len(out), "data": {"discovery": out}}
    
    item = params.get("item", "")
    
    parts = item.split(" - ")
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    sql_res = ctx.run(["hdbsql", "-j", "-U", "SYSTEMDB"], mutates=False)
    
    if sql_res.rc != 0:
        return {"changed": False, "msg": "cannot connect to SAP HANA database: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": sql_res.stderr}}
    
    query_res = ctx.run(["hdbsql", "-j", "-U", "SYSTEMDB", "SELECT STATUS_NAME, STATUS_VALUE FROM M_DATABASE"], mutates=False)
    
    if query_res.rc != 0:
        return {"changed": False, "msg": "query failed for SAP HANA database: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": query_res.stderr}}
    
    if not query_res.stdout:
        return {"changed": False, "msg": "no data from SAP HANA database: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parsed = json.decode(query_res.stdout)
    
    db_status = ""
    for row in parsed:
        if type(row) == "dict":
            status_name = ""
            status_value = ""
            for k in row.keys():
                kl = k.lower()
                if kl == "status_name":
                    status_name = row[k]
                if kl == "status_value":
                    status_value = row[k]
            if status_name == "database_status":
                db_status = status_value
    
    if not db_status:
        return {"changed": False, "msg": "Login into database failed for: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    _MAP_DB_STATUS = {"OK": "OK", "WARNING": "WARN"}
    
    repl_res = ctx.run(["hdbsql", "-j", "-U", "SYSTEMDB", "SELECT SIDE, SYS_REPL_STATUS FROM M_SERVICE_RESOURCES"], mutates=False)
    
    repl_state = None
    if repl_res.rc == 0 and repl_res.stdout:
        repl_parsed = json.decode(repl_res.stdout)
        for row in repl_parsed:
            if type(row) == "dict":
                for k in row.keys():
                    if k.lower() == "sys_repl_status":
                        repl_state = row[k]
    
    db_state = _MAP_DB_STATUS.get(db_status, "CRIT")
    
    if db_state == "CRIT" and repl_state != None and str(repl_state).lower() == "passive":
        return {"changed": False, "msg": "System is in passive mode", "data": {"state": "OK", "metrics": {}, "details": ""}}
    
    state = _MAP_DB_STATUS.get(db_status, "CRIT")
    return {"changed": False, "msg": db_status, "data": {"state": state, "metrics": {}, "details": ""}}