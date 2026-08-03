def main(ctx, params):
    def get_lists():
        # Probe for the real thing: the mailman binary / lists directory.
        # Mailman 2.x stores list names in /var/lib/mailman/lists (one dir per list).
        # Mailman 3.x uses `mailman lists --quiet` but is not installed here.
        lists = []
        res = ctx.run(["ls", "-1", "/var/lib/mailman/lists"], mutates=False)
        if res.rc == 0:
            for line in res.stdout.splitlines():
                name = line.strip()
                if name and name != "mailman":
                    lists.append(name)
        return lists

    if params.get("_discover"):
        lists = get_lists()
        if len(lists) == 0:
            return {"changed": False, "msg": "no mailman lists found",
                    "data": {"discovery": []}}
        out = []
        for name in lists:
            out.append({"item": name, "params": {}, "metrics": ["count"]})
        return {"changed": False,
                "msg": "discovered %d mailing lists" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    lists = get_lists()
    for name in lists:
        if name == item:
            res = ctx.run(["/var/lib/mailman/bin/list_lists", "-b", name],
                          mutates=False)
            if res.rc != 0:
                # Fallback: count from list_members if available.
                res2 = ctx.run(["/var/lib/mailman/bin/list_members", name],
                               mutates=False)
                if res2.rc == 0:
                    num_members = len([l for l in res2.stdout.splitlines()
                                       if l.strip()])
                else:
                    return {"changed": False,
                            "msg": "Could not determine members for " + name,
                            "data": {"state": "UNKNOWN", "metrics": {},
                                     "details": ""}}
            else:
                # list_lists output: first column is member count.
                line = res.stdout.splitlines()[0].strip()
                num_members = 0
                parts = line.split()
                if len(parts) > 0:
                    first = parts[0]
                    num_members = int(first) if first.isdigit() else 0
            return {"changed": False,
                    "msg": "%d members subscribed" % num_members,
                    "data": {"state": "OK",
                             "metrics": {"count": num_members},
                             "details": ""}}
    return {"changed": False,
            "msg": "List could not be found in agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}