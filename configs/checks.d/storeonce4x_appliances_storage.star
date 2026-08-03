def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "no HPE StoreOnce appliances reachable on this host",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    return {
        "changed": False,
        "msg": "no HPE StoreOnce appliance found for item: " + str(item),
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "No HPE StoreOnce appliance data available on this host. This check requires a StoreOnce REST API special agent.",
        },
    }