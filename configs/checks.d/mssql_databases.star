def _parse_databases(raw_rows):
    headers = ["Instance", "DBname", "Status", "Recovery", "auto_close", "auto_shrink"]
    parsed = {}
    if not raw_rows:
        return parsed
    rows = []
    for line in raw_rows:
        if line == headers:
            continue
        if len(line) == 6:
            rows.append(list(line))
        elif len(line) == 7:
            rows.append(list(line[:2]) + ["%s %s" % (line[2], line[3])] + list(line[4:]))
    for line in rows:
        if len(line) < 6:
            continue
        data = {
            "Instance": line[0],
            "DBname": line[1],
            "Status": line[2],
            "Recovery": line[3],
            "auto_close": line[4],
            "auto_shrink": line[5],
        }
        key = "%s %s" % (data["Instance"], data["DBname"])
        parsed.setdefault(key, data)
    return parsed


def _read_mssql_section(ctx):
    path = "/var/lib/cmk/mssql_databases"
    if not ctx.file_exists(path):
        return []
    content = ctx.file_read(path)
    rows = []
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(line.split())
    return rows


def main(ctx, params):
    if params.get("_discover"):
        raw_rows = _read_mssql_section(ctx)
        section = _parse_databases(raw_rows)
        discovery = []
        for key in section:
            discovery.append({
                "item": key,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d mssql databases" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    raw_rows = _read_mssql_section(ctx)
    section = _parse_databases(raw_rows)
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "no mssql database found for item: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    db_state = data.get("Status", "")
    if db_state.startswith("ERROR: "):
        return {
            "changed": False,
            "msg": db_state[7:],
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": db_state,
            },
        }

    state_map = params.get("map_db_states", {})
    state_int = state_map.get(db_state.replace(" ", "_").upper(), 0)
    state = "OK"
    if state_int == 1:
        state = "WARN"
    elif state_int == 2:
        state = "CRIT"
    elif state_int == 3:
        state = "UNKNOWN"

    map_auto_states = {
        "auto_close": params.get("map_auto_close_state", {}),
        "auto_shrink": params.get("map_auto_shrink_state", {}),
    }
    map_states = {"1": (1, "on"), "0": (0, "off")}

    msgs = ["Status: %s" % db_state]
    final_state = state
    for what in ["close", "shrink"]:
        val = data.get("auto_%s" % what, "0")
        if val not in map_states:
            continue
        s_int, s_readable = map_states[val]
        s_int = map_auto_states.get("auto_%s" % what, {}).get(s_readable, s_int)
        if s_int == 1:
            final_state = "WARN"
        elif s_int == 2 and final_state != "CRIT":
            final_state = "CRIT"
        msgs.append("Auto %s: %s" % (what, s_readable))

    msgs.append("Recovery: %s" % data.get("Recovery", ""))

    return {
        "changed": False,
        "msg": ", ".join(msgs),
        "data": {
            "state": final_state,
            "metrics": {},
            "details": ", ".join(msgs),
        },
    }