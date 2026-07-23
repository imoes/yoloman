def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 MongoDB instance",
            "data": {
                "discovery": [{"item": "", "params": {}, "metrics": []}]
            }
        }

    res = ctx.run(["mongo", "--quiet", "--eval", "db.adminCommand('ping')"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "MongoDB instance error: connection failed",
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }

    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "MongoDB instance error: no response",
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }

    status = "OK"
    summary = "Instance: connected"

    if res.stdout.find("ok") != -1 and res.stdout.find("1") != -1:
        summary = "Instance: primary"
    elif res.stdout.find("ok") != -1 and res.stdout.find("secondary") != -1:
        summary = "Instance: secondary"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }