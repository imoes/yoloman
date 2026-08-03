# Checkmk check: mysql_galerastartup
# MySQL Galera Startup - monitors whether a Galera cluster has been
# properly bootstrapped by checking the wsrep_cluster_address variable.
# A value of "gcomm://" means the cluster address is empty (not bootstrapped).


def _has_wsrep_provider(data):
    provider = data.get("wsrep_provider")
    if provider == None:
        return False
    if provider == "none":
        return False
    return True


def _query_mysql_wsrep_vars(ctx):
    # Query MySQL for wsrep-related variables using the local socket.
    # Returns a dict mapping variable_name -> value, or None if MySQL
    # is not available or wsrep is not configured.
    res = ctx.run(
        ["mysql", "--batch", "--raw", "--skip-column-names",
         "-e", "SHOW VARIABLES LIKE 'wsrep_%';"],
        mutates=False,
    )
    if res.rc != 0:
        return None
    if res.stdout == None or res.stdout.strip() == "":
        return None
    data = {}
    for line in res.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        key = parts[0]
        value = parts[1]
        data[key] = value
    if len(data) == 0:
        return None
    return data


def main(ctx, params):
    if params.get("_discover"):
        section = _query_mysql_wsrep_vars(ctx)
        if section == None:
            return {"changed": False, "msg": "no MySQL instance with Galera found",
                    "data": {"discovery": []}}
        if not _has_wsrep_provider(section):
            return {"changed": False, "msg": "no MySQL instance with Galera found",
                    "data": {"discovery": []}}
        if section.get("wsrep_cluster_address") == None:
            return {"changed": False, "msg": "no MySQL instance with Galera found",
                    "data": {"discovery": []}}
        # This is a single-instance check; item is "" since there is one
        # MySQL service per host in this local-socket model.
        return {"changed": False,
                "msg": "discovered 1 MySQL Galera startup service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}
        # --- check mode (non-discovery) ---
    # This is a single-service check; item defaults to ""
    section = _query_mysql_wsrep_vars(ctx)
    if section == None:
        return {"changed": False,
                "msg": "no MySQL instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    wsrep_cluster_address = section.get("wsrep_cluster_address")
    if wsrep_cluster_address == None:
        return {"changed": False,
                "msg": "wsrep_cluster_address is missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if wsrep_cluster_address == "gcomm://":
        return {"changed": False,
                "msg": "WSREP cluster address is empty",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False,
            "msg": "WSREP cluster address: %s" % wsrep_cluster_address,
            "data": {"state": "OK", "metrics": {}, "details": ""}}