def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/etc/passwd"], mutates=False)
        # Placeholder: real check would call the actual data source
        # Since we have no direct agent output, we assume a mock probe
        # In practice, replace with actual CLI that produces the ibm_svc_nodestats section
        # For now, return empty discovery as no probe is defined in runtime context
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    item = params.get("item", "")
    # No actual data source available in runtime; return UNKNOWN
    return {"changed": False, "msg": "no data source available for node " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}