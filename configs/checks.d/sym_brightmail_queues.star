def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: Symantec Brightmail / Messaging Gateway
        # detected via sysDescr containing "el5_sms" or "el6".
        probe = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Ovqn",
                params.get("host", "localhost"),
                ".1.3.6.1.2.1.1.1.0",
            ],
            mutates=False,
        )
        sd = probe.stdout.strip() if probe.stdout else ""
        if probe.rc != 0 or "el5_sms" not in sd and "el6" not in sd:
            return {"changed": False, "msg": "no Brightmail queues found",
                    "data": {"discovery": []}}

        # Walk the queue table (columns 2..8) with a clean numeric OID walk.
        base = ".1.3.6.1.4.1.393.200.130.2.2.1.1"
        walk = ctx.run(
            [
                "snmpwalk",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                base,
            ],
            mutates=False,
        )
        rows = {}
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            # index is the suffix after base + ".<col>"
            rest = oid[len(base) + 1:]
            parts = rest.split(".", 1)
            if len(parts) != 2:
                continue
            col = parts[0]
            idx = parts[1]
            rows.setdefault(idx, {})[col] = val

        # column .2 is the queue name (desc); .3..8 are the metrics
        discovery = []
        for idx in sorted(rows.keys()):
            cols = rows[idx]
            descr = cols.get("2", "")
            if descr == "":
                continue
            discovery.append({
                "item": descr,
                "params": {},
                "metrics": [
                    "connections",
                    "dataRate",
                    "deferredMessages",
                    "messageRate",
                    "queueSize",
                    "queuedMessages",
                ],
            })
        return {"changed": False,
                "msg": "discovered %d queues" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.393.200.130.2.2.1.1"

    # Fetch one column at a time keyed by the item's queue name -> index.
    # Walk column .2 (description) to map name -> index.
    walk2 = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            base + ".2",
        ],
        mutates=False,
    )
    idx_for = {}
    for line in walk2.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        rest = oid[len(base) + 1:]
        parts = rest.split(".", 1)
        if len(parts) != 2:
            continue
        idx_for[val.strip()] = parts[1]

    idx = idx_for.get(item)
    if idx == None:
        return {"changed": False, "msg": "no such queue: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cols = {}
    for col in ["3", "4", "5", "6", "7", "8"]:
        g = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqv",
                params.get("host", "localhost"),
                base + "." + col + "." + idx,
            ],
            mutates=False,
        )
        if g.rc == 0 and g.stdout != "":
            cols[col] = g.stdout.strip()

    data = {
        "connections": cols.get("3", ""),
        "dataRate": cols.get("4", ""),
        "deferredMessages": cols.get("5", ""),
        "messageRate": cols.get("6", ""),
        "queueSize": cols.get("7", ""),
        "queuedMessages": cols.get("8", ""),
    }

    metrics = {}
    details = []
    state = "OK"
    label_map = {
        "connections": "Connections",
        "dataRate": "Data rate",
        "deferredMessages": "Deferred messages",
        "messageRate": "Message rate",
        "queueSize": "Queue size",
        "queuedMessages": "Queued messages",
    }
    col_map = {
        "connections": "3",
        "dataRate": "4",
        "deferredMessages": "5",
        "messageRate": "6",
        "queueSize": "7",
        "queuedMessages": "8",
    }

    for key, title in label_map.items():
        raw = data.get(key, "")
        if raw == "":
            continue
        val = int(raw) if raw.lstrip("-").isdigit() else 0
        metrics[key] = val
        lvls = params.get(key)
        if lvls != None:
            warn = lvls[0] if len(lvls) > 0 else None
            crit = lvls[1] if len(lvls) > 1 else None
        else:
            warn = None
            crit = None
        lvl = ""
        if crit != None and val >= crit:
            lvl = "!!"
            state = "CRIT"
        elif warn != None and val >= warn:
            lvl = "!"
            if state != "CRIT":
                state = "WARN"
        details.append("%s: %d%s" % (title, val, lvl))

    summary = "; ".join(details) if details else "no data"
    return {"changed": False, "msg": "Queue %s: %s" % (item, summary),
            "data": {"state": state, "metrics": metrics, "details": summary}}