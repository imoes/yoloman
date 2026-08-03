DEVICE_STATES_V4 = {
    0: ("OK", "normal"),
    1: ("CRIT", "disabled"),
    2: ("CRIT", "purged"),
    5: ("WARN", "reading"),
    6: ("WARN", "settle"),
    7: ("CRIT", "not found"),
    8: ("CRIT", "lost"),
    9: ("CRIT", "read error"),
    10: ("CRIT", "no comm"),
    11: ("CRIT", "pwr error"),
    12: ("CRIT", "breaker tripped"),
    13: ("CRIT", "fuse blown"),
    14: ("CRIT", "low alarm"),
    15: ("WARN", "low warning"),
    16: ("WARN", "high warning"),
    17: ("CRIT", "high alarm"),
    18: ("CRIT", "alarm"),
    19: ("CRIT", "under limit"),
    20: ("CRIT", "over limit"),
    21: ("CRIT", "nvm fail"),
    22: ("CRIT", "profile error"),
    23: ("CRIT", "conflict"),
}

BASE_OID = ".1.3.6.1.4.1.1718.4.1.8"
SYSOID = ".1.3.6.1.2.1.1.2.0"
EXPECT_SYSOID = ".1.3.6.1.4.1.1718.4"


def _fetch_table(ctx, community, host):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, BASE_OID],
        mutates=False,
    )
    if res.rc != 0:
        return {}
    columns = {}
    for line in res.stdout.splitlines():
        idx = line.find(" ")
        if idx == -1:
            continue
        oid = line[:idx]
        value = line[idx + 1:]
        if len(oid) <= len(BASE_OID):
            continue
        suffix = oid[len(BASE_OID) + 1:]
        dots = suffix.split(".")
        if len(dots) < 2:
            continue
        col = ".".join(dots[:-1])
        inst = dots[-1]
        columns[(col, inst)] = value
    return columns


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        sysres = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSOID],
            mutates=False,
        )
        if sysres.rc != 0:
            return {"changed": False, "msg": "not a Sentry PDU (no sysOID)", "data": {"discovery": []}}
        if sysres.stdout.strip() != EXPECT_SYSOID:
            return {"changed": False, "msg": "not a Sentry PDU v4", "data": {"discovery": []}}

        columns = _fetch_table(ctx, community, host)
        names = {}
        states = {}
        for key, value in columns.items():
            col, inst = key
            if col == "2.1.2":
                names[inst] = value.replace("Outlet", "")
            elif col == "3.1.2":
                states[inst] = value

        items = []
        for inst in sorted(states.keys()):
            name = names.get(inst, inst)
            item = "%s %s" % (inst, name)
            items.append({"item": item, "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d outlets" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    sysres = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSOID],
        mutates=False,
    )
    if sysres.rc != 0:
        return {
            "changed": False,
            "msg": "not a Sentry PDU (no sysOID)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    columns = _fetch_table(ctx, community, host)
    parts = item.split(" ", 1)
    inst = parts[0] if len(parts) > 0 else ""

    state_key = ("3.1.2", inst)
    if state_key not in columns:
        return {
            "changed": False,
            "msg": "outlet %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_str = columns.get(state_key, "")
    outlet_state = int(state_str) if state_str.strip().isdigit() else -1

    if outlet_state in DEVICE_STATES_V4:
        state, status = DEVICE_STATES_V4[outlet_state]
        msg = "Status: %s" % status
    else:
        state = "UNKNOWN"
        msg = "Unhandled state: %s" % str(outlet_state)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }