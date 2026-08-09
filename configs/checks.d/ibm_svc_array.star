def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "No local IBM SVC array data source available",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    return {
        "changed": False,
        "msg": "IBM SVC array %s not found: no local data source (data comes from the IBM SVC special agent)" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "IBM SVC arrays are monitored via the IBM SVC special agent over the network; no on-host data source is available on this host.",
        },
    }