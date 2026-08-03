def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base1 = ".1.3.6.1.4.1.2620.1.1"
    base2 = ".1.3.6.1.4.1.2620.1.2.5.4"

    # Probe for the real thing: Check Point / IPSO system OID
    sysid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    sys_desc = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    is_checkpoint = False
    if sysid.rc == 0 and sysid.stdout.strip().startswith(".1.3.6.1.4.1.2620"):
        is_checkpoint = True
    if not is_checkpoint and sys_desc.rc == 0:
        desc = sys_desc.stdout.strip().lower()
        if desc.startswith("ipso ") or "cpx" in desc:
            is_checkpoint = True

    if not is_checkpoint:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "discovered 0 items (not a Check Point/IPSO system)",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "not a Check Point/IPSO system (no Check Point system OID)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "System does not appear to be a Check Point/IPSO device.",
            },
        }

    if params.get("_discover"):
        t1 = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base1 + ".4"],
            mutates=False,
        )
        t2 = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base2 + ".5"],
            mutates=False,
        )
        if t1.rc != 0 and t2.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 items (no packet statistics OIDs)",
                "data": {"discovery": []},
            }
        metrics = [
            "accepted", "rejected", "dropped", "logged",
            "espencrypted", "espdecrypted",
        ]
        defaults = {
            "accepted": 100000,
            "rejected": 100000,
            "dropped": 100000,
            "logged": 100000,
            "espencrypted": 100000,
            "espdecrypted": 100000,
        }
        crit_defaults = {
            "accepted": 200000,
            "rejected": 200000,
            "dropped": 200000,
            "logged": 200000,
            "espencrypted": 200000,
            "espdecrypted": 200000,
        }
        params_disc = {}
        for k in metrics:
            params_disc[k] = [defaults[k], crit_defaults[k]]
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": params_disc, "metrics": metrics}
                ]
            },
        }

    # CHECK MODE
    cols1 = [base1 + ".4", base1 + ".5", base1 + ".6", base1 + ".7"]
    vals1 = {}
    for col in cols1:
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, col + ".0"],
            mutates=False,
        )
        if res.rc == 0 and res.stdout.strip().isdigit():
            vals1[col] = int(res.stdout.strip())

    cols2 = [base2 + ".5", base2 + ".6"]
    vals2 = {}
    for col in cols2:
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, col + ".0"],
            mutates=False,
        )
        if res.rc == 0 and res.stdout.strip().isdigit():
            vals2[col] = int(res.stdout.strip())

    keys = [
        ("Accepted", vals1.get(base1 + ".4")),
        ("Rejected", vals1.get(base1 + ".5")),
        ("Dropped", vals1.get(base1 + ".6")),
        ("Logged", vals1.get(base1 + ".7")),
        ("EspEncrypted", vals2.get(base2 + ".5")),
        ("EspDecrypted", vals2.get(base2 + ".6")),
    ]

    # No data gathered
    has_data = False
    for _, v in keys:
        if v != None:
            has_data = True
            break
    if not has_data:
        return {
            "changed": False,
            "msg": "no packet statistics available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Check Point packet statistics OIDs returned no values.",
            },
        }

    now = ctx.run(["date", "+%s"], mutates=False)
    this_time = 0.0
    if now.rc == 0 and now.stdout.strip().isdigit():
        this_time = float(now.stdout.strip())

    prev = ctx.run(["cat", "/tmp/cmk_checkpoint_packets_state"], mutates=False)
    old_time = 0.0
    old_vals = {}
    if prev.rc == 0 and prev.stdout != "":
        old = json.decode(prev.stdout)
        old_time = float(old.get("time", 0.0))
        old_vals = old.get("vals", {})

    states = []
    metrics_out = {}
    details_lines = []

    defaults = {
        "accepted": (100000, 200000),
        "rejected": (100000, 200000),
        "dropped": (100000, 200000),
        "logged": (100000, 200000),
        "espencrypted": (100000, 200000),
        "espdecrypted": (100000, 200000),
    }

    for name, value in keys:
        if value == None:
            continue
        key = name.lower()
        rate = 0.0
        elapsed = this_time - old_time
        if elapsed > 0 and key in old_vals and old_time > 0:
            old_v = old_vals.get(key, value)
            if value >= old_v:
                rate = (value - old_v) / elapsed

        lvl = params.get(key)
        if lvl == None:
            d = defaults.get(key, (100000, 200000))
            warn = d[0]
            crit = d[1]
        else:
            if len(lvl) > 0:
                warn = lvl[0]
            else:
                warn = 100000
            if len(lvl) > 1:
                crit = lvl[1]
            else:
                crit = 200000

        if rate >= crit:
            st = "CRIT"
        elif rate >= warn:
            st = "WARN"
        else:
            st = "OK"
        states.append(st)
        metrics_out[key] = rate
        details_lines.append(
            "%s: %f pkts/s (%s)" % (name, rate, st)
        )

    if len(states) == 0:
        overall = "UNKNOWN"
    else:
        if "CRIT" in states:
            overall = "CRIT"
        elif "WARN" in states:
            overall = "WARN"
        else:
            overall = "OK"

    msg = ", ".join(details_lines)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall,
            "metrics": metrics_out,
            "details": "\n".join(details_lines),
        },
    }