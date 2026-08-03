def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "not installed", "data": {"discovery": [], "host_labels": {}}}
    return {"changed": False, "msg": "ororacle processes not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}