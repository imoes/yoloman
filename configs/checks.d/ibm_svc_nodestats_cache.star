def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

    item = params.get("item", "")
    return {
        "changed": False,
        "msg": "IBM SVC storage array not reachable: no on-host agent data source for ibm_svc_nodestats",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "No IBM SVC nodestats data available on this host (special agent / network API required).",
        },
    }