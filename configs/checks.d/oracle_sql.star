# ===== check plugin: cmk/plugins/oracle/agent_based/oracle_sql.py =====

# Checkmk check: oracle_sql
# Monitors Oracle SQL instance health via SQL queries.
# Probes for Oracle presence; if not installed/running, discovery returns empty.

def main(ctx, params):
    if params.get("_discover"):
        return _discover_oracle_sql(ctx, params)
    return _check_oracle_sql(ctx, params)

def _probe_oracle(ctx):
    # Probe for Oracle: check for sqlplus binary or Oracle processes
    res = ctx.run(["which", "sqlplus"], mutates=False)
    if res.rc == 0 and res.stdout.strip():
        return True
    # Also check for Oracle background processes
    ps = ctx.run(["ps", "aux"], mutates=False)
    for line in ps.stdout.splitlines():
        if "ora_" in line or "pmon" in line.lower():
            return True
    return False

def _discover_oracle_sql(ctx, params):
    if not _probe_oracle(ctx):
        return {"changed": False, "msg": "no Oracle found", 
                "data": {"discovery": [], "host_labels": {}}}
    
    # Try to get instance SIDs via sqlplus
    instances = _get_oracle_instances(ctx)
    discovery = []
    for sid in instances:
        item = "%s SQL *" % sid.upper()
        discovery.append({
            "item": item,
            "params": {},
            "metrics": ["elapsed_time"]
        })
    return {"changed": False, "msg": "discovered %d Oracle instances" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}}}

def _get_oracle_instances(ctx):
    # Try to connect to Oracle and list instances
    # This is a best-effort: we need credentials which aren't available
    # Return empty - without credentials we can't query Oracle
    return []

def _check_oracle_sql(ctx, params):
    if not _probe_oracle(ctx):
        return {"changed": False, "msg": "no Oracle instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Oracle not installed"}}
    
    item = params.get("item", "")
    # Without credentials, we can't run the actual SQL queries
    # Report UNKNOWN as we have no data
    return {"changed": False, "msg": "Oracle SQL check: no data available without credentials",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}