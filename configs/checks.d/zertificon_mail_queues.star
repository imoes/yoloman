def main(ctx, params):
    base = "1.3.6.1.4.1.2021.8.1.100"
    cols = ["5", "6", "7", "8", "9", "10", "17"]
    labels = [
        "mail_queue_postfix_total",
        "mail_queue_incoming_length",
        "mail_queue_active_length",
        "mail_queue_deferred_length",
        "mail_queue_hold_length",
        "mail_queue_drop_length",
        "mail_queue_z1_messenger",
    ]

    def snmpget_oid(oid):
        res = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c", params.get("community", "public"),
                "-Oqv",
                params.get("host", "localhost"),
                oid,
            ],
            mutates=False,
        )
        return res

    # probe for the real Zertificon appliance via sysoid / a base OID
    probe = snmpget_oid(base + "." + cols[0])
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "Zertificon appliance not present (no SNMP response)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # discovery mode
    if params.get("_discover"):
        values = []
        ok = True
        for c in cols:
            r = snmpget_oid(base + "." + c)
            if r.rc != 0 or not r.stdout.strip():
                ok = False
                break
            val = r.stdout.strip()
            if not val.lstrip("-").isdigit():
                ok = False
                break
            values.append(int(val))
        if not ok:
            return {
                "changed": False,
                "msg": "Zertificon appliance not present",
                "data": {"discovery": []},
            }
        metrics = list(labels)
        return {
            "changed": False,
            "msg": "discovered Zertificon Mail Queues",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": metrics,
                    }
                ]
            },
        }

    # check mode — single service, item ""
    values = []
    for c in cols:
        r = snmpget_oid(base + "." + c)
        if r.rc != 0 or not r.stdout.strip():
            return {
                "changed": False,
                "msg": "no Zertificon mail queue data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        val = r.stdout.strip()
        if not val.lstrip("-").isdigit():
            return {
                "changed": False,
                "msg": "invalid Zertificon mail queue data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        values.append(int(val))

    metrics = {}
    for i in range(len(labels)):
        metrics[labels[i]] = values[i]

    crits = []
    warns = []
    for i in range(len(labels)):
        mname = labels[i]
        val = values[i]
        warn = params.get("levels_" + mname)
        if warn != None and type(warn) == "list" and len(warn) >= 2:
            w = warn[0]
            c = warn[1]
            warns.append((mname, val, w))
            crits.append((mname, val, c))

    state = "OK"
    parts = []
    for i in range(len(labels)):
        mname = labels[i]
        val = values[i]
        parts.append("%s: %s" % (mname, str(val)))

    if len(crits) > 0:
        crit_found = False
        for mname, val, c in crits:
            if val >= c:
                crit_found = True
                break
        if crit_found:
            state = "CRIT"
        else:
            warn_found = False
            for mname, val, w in warns:
                if val >= w:
                    warn_found = True
                    break
            if warn_found:
                state = "WARN"

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }