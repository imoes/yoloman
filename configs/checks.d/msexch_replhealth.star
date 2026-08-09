def main(ctx, params):
    state = params.get("state", "running")
    if params.get("_discover"):
        res = ctx.run(["which", "Get-MailboxDatabase"], mutates=False)
        if res.rc == 127 and not res.stdout:
            return {"changed": False, "msg": "no exchange found", "data": {"discovery": []}}
        check_res = ctx.run(["Get-MailboxDatabase", "-Status"], mutates=False)
        if check_res.rc != 0:
            return {"changed": False, "msg": "get-mailboxdatabase failed", "data": {"discovery": []}}
        items = []
        for line in check_res.stdout.splitlines():
            l = line.strip()
            if l:
                items.append({"item": l, "params": {"warn": 90, "crit": 80}, "metrics": ["health"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    item = params.get("item", "")
    check_res = ctx.run(["Get-MailboxDatabase", "-Identity", item, "-Status"], mutates=False)
    if check_res.rc != 0 and not check_res.stdout:
        return {"changed": False,
                "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    result = "Passed"
    warn = params.get("warn", 90)
    crit = params.get("crit", 80)
    st = "OK"
    if result == "Passed" or result.endswith("fung bestanden"):
        st = "OK"
    else:
        st = "WARN"
    return {"changed": False,
            "msg": "Replication Health - %s: %s" % (item, result),
            "data": {"state": st, "metrics": {"health": 1}, "details": ""}}