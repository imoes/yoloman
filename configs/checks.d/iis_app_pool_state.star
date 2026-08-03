def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["which", "iis_app_pool_state"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no IIS found on this host",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}
    item = params.get("item", "")
    return {"changed": False,
            "msg": "no IIS Application Pool " + item + " found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}