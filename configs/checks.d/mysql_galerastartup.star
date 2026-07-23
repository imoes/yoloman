def _has_wsrep_provider(data):
    val = data.get("wsrep_provider")
    return val != None and val != "none"

def main(ctx, params):
    if params.get("_discover"):
        # Probe MySQL status variables via SHOW STATUS and SHOW VARIABLES
        # We need: wsrep_provider, wsrep_cluster_address, wsrep_sst_donor,
        #          wsrep_cluster_size, wsrep_cluster_status, wsrep_local_state_comment
        # Use SHOW VARIABLES for wsrep_provider, wsrep_sst_donor, wsrep_cluster_address
        # Use SHOW STATUS for wsrep_cluster_size, wsrep_cluster_status, wsrep_local_state_comment
        res_vars = ctx.run(["mysql", "-N", "-e", "SHOW VARIABLES LIKE 'wsrep_%'"], mutates=False)
        res_status = ctx.run(["mysql", "-N", "-e", "SHOW STATUS LIKE 'wsrep_%'"], mutates=False)

        # Parse into a dict
        data = {}
        for line in res_vars.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) >= 2:
                data[fields[0]] = fields[1]
        for line in res_status.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) >= 2:
                data[fields[0]] = fields[1]

        # Check if this host has Galera (wsrep_provider present and non-"none")
        # and has wsrep_cluster_address (for startup check)
        if _has_wsrep_provider(data) and data.get("wsrep_cluster_address") != None:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {"item": "mysql", "params": {}, "metrics": []}
                    ]
                }
            }
        else:
            return {
                "changed": False,
                "msg": "no Galera startup data found",
                "data": {
                    "discovery": []
                }
            }

    # Check mode for one item (only "mysql" is expected)
    item = params.get("item", "")
    if item != "mysql":
        return {
            "changed": False,
            "msg": "no such item",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Gather Galera startup data
    res_vars = ctx.run(["mysql", "-N", "-e", "SHOW VARIABLES LIKE 'wsrep_%'"], mutates=False)
    res_status = ctx.run(["mysql", "-N", "-e", "SHOW STATUS LIKE 'wsrep_%'"], mutates=False)

    data = {}
    for line in res_vars.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) >= 2:
            data[fields[0]] = fields[1]
    for line in res_status.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) >= 2:
            data[fields[0]] = fields[1]

    wsrep_cluster_address = data.get("wsrep_cluster_address")

    if wsrep_cluster_address == None:
        return {
            "changed": False,
            "msg": "WSREP cluster address missing",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    if wsrep_cluster_address == "gcomm://":
        return {
            "changed": False,
            "msg": "WSREP cluster address is empty",
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }

    return {
        "changed": False,
        "msg": "WSREP cluster address configured",
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }