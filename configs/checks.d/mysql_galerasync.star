# Checkmk check: mysql_galerasync (MySQL Galera Sync %s)
# Translated to a read-only Starlark check module for the yolo-man agent.

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _mysql_running(ctx):
    res = ctx.run(["mysqladmin", "--version"], mutates=False)
    return res.rc == 0


def _mysql_vars(ctx):
    if not _mysql_running(ctx):
        return None
    query = "SELECT GROUP_CONCAT(CONCAT(variable_name,'=',IFNULL(variable_value,''))) FROM (SELECT variable_name, variable_value FROM performance_schema.global_status WHERE variable_name LIKE 'wsrep_%' ORDER BY variable_name) s;"
    cmd = ["mysql", "--batch", "--skip-column-names", "--raw", "-e", query]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    data = {}
    for token in res.stdout.splitlines():
        token = token.strip()
        if token == "":
            continue
        if "=" in token:
            k, v = token.split("=", 1)
            data[k.strip()] = v.strip()
    return data


def _galera_active(data):
    if data == None:
        return False
    provider = data.get("wsrep_provider", "")
    if provider == None:
        return False
    if provider == "none":
        return False
    if provider == "":
        return False
    return True


def _discover(ctx, params):
    if not _mysql_running(ctx):
        return {"changed": False, "msg": "mysql not installed",
                "data": {"discovery": []}}

    data = _mysql_vars(ctx)
    if not _galera_active(data):
        return {"changed": False, "msg": "no Galera provider active",
                "data": {"discovery": []}}

    if "wsrep_local_state_comment" not in data:
        return {"changed": False, "msg": "wsrep_local_state_comment missing",
                "data": {"discovery": []}}

    instance = "mysql"
    return {
        "changed": False,
        "msg": "discovered MySQL Galera sync status",
        "data": {
            "discovery": [
                {
                    "item": instance,
                    "params": {},
                    "metrics": [],
                }
            ]
        },
    }


def _check(ctx, params):
    if not _mysql_running(ctx):
        return {"changed": False, "msg": "mysql not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = _mysql_vars(ctx)
    if not _galera_active(data):
        return {"changed": False, "msg": "no Galera provider active",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    comment = data.get("wsrep_local_state_comment")
    if comment == None:
        return {"changed": False, "msg": "wsrep_local_state_comment missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if comment == "Synced":
        state = "OK"
    else:
        state = "CRIT"

    return {
        "changed": False,
        "msg": "WSREP local state comment: %s" % comment,
        "data": {
            "state": state,
            "metrics": {},
            "details": "wsrep_local_state_comment=%s" % comment,
        },
    }