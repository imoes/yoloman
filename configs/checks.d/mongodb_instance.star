def main(ctx, params):
    if params.get("_discover"):
        if not _is_mongodb_running(ctx):
            return {"changed": False, "msg": "MongoDB not running", "data": {"discovery": []}}
        out = [{"item": "", "params": {}, "metrics": []}]
        return {"changed": False, "msg": "discovered MongoDB Instance", "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["mongo", "--quiet", "--eval", "db.adminCommand({replSetGetStatus: 1})"], mutates=False)
    if res.rc != 0:
        if res.rc == 127:
            return {"changed": False, "msg": "mongo client not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "no MongoDB instance found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if _is_error(res.stdout):
        return {"changed": False, "msg": _status(res.stdout) + ": " + _message(res.stdout), "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": _status(res.stdout) + ": " + _message(res.stdout), "data": {"state": "OK", "metrics": {}, "details": ""}}


def _is_mongodb_running(ctx):
    res = ctx.run(["pgrep", "-x", "mongod"], mutates=False)
    return res.rc == 0


def _is_error(stdout):
    lowered = stdout.lower()
    return lowered.find("error") >= 0 or lowered.find("not master") >= 0


def _status(stdout):
    lowered = stdout.lower()
    if lowered.find("error") >= 0:
        return "Error"
    if lowered.find("secondary") >= 0:
        return "Secondary"
    if lowered.find("primary") >= 0:
        return "Primary"
    if lowered.find("not master") >= 0:
        return "Error"
    return "Unknown"


def _message(stdout):
    return stdout.strip() if stdout.strip() else "no output"