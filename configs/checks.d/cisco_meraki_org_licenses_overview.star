def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {
                "discovery": []
            }
        }
    return {
        "changed": False,
        "msg": "Meraki Dashboard API not configured",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }