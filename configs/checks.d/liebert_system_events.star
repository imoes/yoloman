# Translated Checkmk check plugin: liebert_system_events
# READ-ONLY Starlark module — never mutates, never file_writes.
# Data source: SNMP (Liebert GP Flexible MIB), not Checkmk internals.

def _snmp_get_table(ctx, host, community, column_oid):
    # -Oqn gives one line per row: "<columnOID>.<index> <value>"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    rows = []  # list of [oid_full, value]
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        rows.append([parts[0], parts[1]])
    return rows


def _snmp_get_value(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _parse_events(label_rows, value_rows):
    # label_rows: list of [oid_full, value] for the label column (10.1.2.100)
    # value_rows: list of [oid_full, value] for the value column (20.1.2.100)
    label_base = ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.100"
    value_base = ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.100"
    events = {}
    for oid_full, value in value_rows:
        index = oid_full[len(value_base) + 1:]
        events[index] = value
    for oid_full, value in label_rows:
        index = oid_full[len(label_base) + 1:]
        if index in events:
            events[index] = [value, events[index]]
    parsed = {}
    used_names = {}
    for index in sorted(events.keys()):
        pair = events[index]
        if len(pair) < 2:
            continue
        name = pair[0]
        if not name:
            continue
        if name in used_names:
            used_names[name] += 1
            final_name = "%s %d" % (name, used_names[name])
        else:
            used_names[name] = 1
            final_name = name
        parsed[final_name] = pair[1]
    return parsed


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    label_col = base + ".10.1.2.100"
    value_col = base + ".20.1.2.100"
    sysoid_col = ".1.3.6.1.2.1.1.2.0"

    if params.get("_discover"):
        # Verify Liebert device presence via sysObjectID prefix
        sysoid = _snmp_get_value(ctx, host, community, sysoid_col)
        if not sysoid or not sysoid.startswith(".1.3.6.1.4.1.476.1.42"):
            return {"changed": False, "msg": "not a Liebert device", "data": {"discovery": []}}
        label_rows = _snmp_get_table(ctx, host, community, label_col)
        value_rows = _snmp_get_table(ctx, host, community, value_col)
        events = _parse_events(label_rows, value_rows)
        if not events:
            return {"changed": False, "msg": "no Liebert system events found", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered Liebert system events",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ],
            },
        }

    # CHECK mode — single service (item "")
    sysoid = _snmp_get_value(ctx, host, community, sysoid_col)
    if not sysoid or not sysoid.startswith(".1.3.6.1.4.1.476.1.42"):
        return {
            "changed": False,
            "msg": "not a Liebert device (sysObjectID mismatch)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    label_rows = _snmp_get_table(ctx, host, community, label_col)
    value_rows = _snmp_get_table(ctx, host, community, value_col)
    events = _parse_events(label_rows, value_rows)

    if not events:
        return {
            "changed": False,
            "msg": "Normal (no events)",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    active_events = []
    for k in sorted(events.keys()):
        v = events[k]
        if not k or not v:
            continue
        if v.lower() == "inactive event":
            continue
        active_events.append((k, v))

    if not active_events:
        return {
            "changed": False,
            "msg": "Normal",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    summaries = []
    for k, v in active_events:
        summaries.append("%s: %s" % (k, v))
    return {
        "changed": False,
        "msg": "; ".join(summaries),
        "data": {"state": "CRIT", "metrics": {}, "details": ""},
    }