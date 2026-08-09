def _snmp_get_table(ctx, community, host, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp+1:]
        idx = oid[len(column_oid)+1:]
        if idx:
            rows.append({"index": idx, "oid": oid, "value": val})
    return rows

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base = ".1.3.6.1.4.1.52.4.3.1.3.1.1"
    num_col = base + ".1"

    if params.get("_discover"):
        rows = _snmp_get_table(ctx, community, host, num_col)
        out = []
        for r in rows:
            state_val = None
            state_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host,
                 base + ".2." + r["index"]],
                mutates=False,
            )
            if state_res.rc == 0:
                state_val = state_res.stdout.strip()
            if state_val == "2":
                continue
            out.append({
                "item": r["index"],
                "params": {"warn": 4, "crit": 4},
                "metrics": ["fan_state"],
            })
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    state_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         base + ".2." + item],
        mutates=False,
    )
    if state_res.rc != 0:
        return {
            "changed": False,
            "msg": "no fan data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = state_res.stdout.strip()
    fan_states = {
        "1": "info not available",
        "2": "not installed",
        "3": "installed and operating",
        "4": "installed and not operating",
    }
    label = fan_states.get(state, "unknown")
    message = "FAN State: " + label

    if state in ["1", "2"]:
        verdict = "UNKNOWN"
    elif state == "4":
        verdict = "CRIT"
    else:
        verdict = "OK"

    state_int = 0
    if state.isdigit():
        state_int = int(state)

    return {
        "changed": False,
        "msg": message,
        "data": {
            "state": verdict,
            "metrics": {"fan_state": state_int},
            "details": "",
        },
    }