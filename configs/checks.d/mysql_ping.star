def main(ctx, params):
    if params.get("_discover"):
        return _do_discover(ctx, params)
    return _do_check(ctx, params)


def _mysql_instances():
    # Instances are configurable: a list of dicts with host/user/socket.
    # Default to none here; discovery reads what mysqladmin can reach.
    return [
        {"host": "localhost", "user": "root"},
    ]


def _mysqladmin_path(ctx):
    res = ctx.run(["mysqladmin", "--version"], mutates=False)
    return res.rc == 0


def _ping(ctx, inst):
    args = ["mysqladmin", "ping"]
    if inst.get("host"):
        args = args + ["-h", inst["host"]]
    if inst.get("user"):
        args = args + ["-u", inst["user"]]
    if inst.get("socket"):
        args = args + ["--socket", inst["socket"]]
    args.append("-X")  # disable column output: plain text
    res = ctx.run(args, mutates=False)
    return res


def _do_discover(ctx, params):
    if not _mysqladmin_path(ctx):
        return {"changed": False, "msg": "mysqladmin not installed",
                "data": {"discovery": []}}

    instances = params.get("instances", _mysql_instances())
    found = []
    for inst in instances:
        res = _ping(ctx, inst)
        # mysqladmin ping returns 0 when alive, non-zero (e.g. 1) when not.
        # If it cannot connect at all, rc may be 1 and stderr has the reason.
        host = inst.get("host", "localhost")
        item = host
        found.append({
            "item": item,
            "params": {"warn": 0, "crit": 0},
            "metrics": ["mysql_ping_state"],
        })
    return {"changed": False,
            "msg": "discovered %d MySQL instances" % len(found),
            "data": {"discovery": found}}


def _do_check(ctx, params):
    item = params.get("item", "")
    instances = params.get("instances", _mysql_instances())

    if not _mysqladmin_path(ctx):
        return {"changed": False,
                "msg": "mysqladmin not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the instance matching this item (host).
    match = None
    for inst in instances:
        host = inst.get("host", "localhost")
        if host == item:
            match = inst
            break
    if match == None:
        # Also accept empty item meaning the single default instance.
        if item == "" and len(instances) >= 1:
            match = instances[0]

    if match == None:
        return {"changed": False,
                "msg": "no MySQL instance configured for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = _ping(ctx, match)
    out = res.stdout.strip() if res.stdout else ""
    err = res.stderr.strip() if res.stderr else ""

    # mysqladmin ping output is like "mysqld is alive" on success.
    # On failure it returns rc 1 and prints an error message.
    combined = out
    if not combined and err:
        combined = err

    if res.rc == 0 and out == "mysqld is alive":
        return {"changed": False,
                "msg": "MySQL Daemon is alive",
                "data": {"state": "OK", "metrics": {"mysql_ping_state": 0},
                         "details": out}}
    else:
        return {"changed": False,
                "msg": combined,
                "data": {"state": "CRIT", "metrics": {"mysql_ping_state": 1},
                         "details": combined}}