# Starlark module for Checkmk mysql_galerasync check (read-only)
# Translates the Galera sync status check from the Checkmk MySQL plugin

def main(ctx, params):
    # DISCOVERY MODE: enumerate all MySQL instances with Galera wsrep_provider
    # and wsrep_local_state_comment present
    if params.get("_discover"):
        # Run mysql command to fetch global status variables
        res = ctx.run(["mysql", "-N", "-e", "SHOW STATUS LIKE 'wsrep_%'"], mutates=False)
        if res.rc != 0:
            # Agent not available or MySQL not running — no items discovered
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Parse SHOW STATUS output: Variable_name<TAB>Value
        data = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split("\t", 1)
            if len(parts) == 2:
                varname, value = parts
                data[varname] = value
        
        # Check for Galera presence: wsrep_provider must be set (not "none") and
        # wsrep_local_state_comment must exist
        has_provider = data.get("wsrep_provider") not in ("", "none", None)
        has_state = data.get("wsrep_local_state_comment") != None
        
        # Discover one service per MySQL instance (we have a single MySQL instance)
        # In Checkmk, per-item parsing wraps each [[mysql]] section — here we treat
        # the global status as one instance named "mysql"
        if has_provider and has_state:
            return {
                "changed": False,
                "msg": "discovered 1 Galera instance",
                "data": {"discovery": [{"item": "mysql", "params": {}, "metrics": []}]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 Galera instances",
            "data": {"discovery": []},
        }
    
    # CHECK MODE: inspect one item (always "mysql" in this case)
    item = params.get("item", "")
    if item != "mysql":
        # Unexpected item — return UNKNOWN
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    res = ctx.run(["mysql", "-N", "-e", "SHOW STATUS LIKE 'wsrep_%'"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve Galera status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse SHOW STATUS output
    data = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split("\t", 1)
        if len(parts) == 2:
            varname, value = parts
            data[varname] = value
    
    # Check required keys: wsrep_provider and wsrep_local_state_comment
    wsrep_local_state_comment = data.get("wsrep_local_state_comment")
    
    if wsrep_local_state_comment == None:
        return {
            "changed": False,
            "msg": "Galera sync status not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # State logic: Synced -> OK, else CRIT
    state = "OK" if wsrep_local_state_comment == "Synced" else "CRIT"
    
    return {
        "changed": False,
        "msg": "WSREP local state comment: " + wsrep_local_state_comment,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }