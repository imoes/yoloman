# brocade_mlx_power — translated from Checkmk check plugin
# Monitors Brocade MLX power supply states via SNMP (read-only).

OID_OLD = ".1.3.6.1.4.1.1991.1.1.1.2.1.1"
OID_NEW = ".1.3.6.1.4.1.1991.1.1.1.2.2.1"

STATE_OK = "OK"
STATE_CRIT = "CRIT"
STATE_UNKNOWN = "UNKNOWN"

MLX_SYS_OID_PREFIX = ".1.3.6.1.4.1.1991.1."


def _walk_table(ctx, host, community, base_oid, wanted_cols):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return {}

    wanted = {}
    for w in wanted_cols:
        wanted[w] = True

    rows = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        full_oid = parts[0]
        value = parts[1]

        suffix = full_oid
        if suffix.startswith(base_oid + "."):
            suffix = suffix[len(base_oid) + 1:]
        else:
            continue

        oid_parts = suffix.split(".")
        if len(oid_parts) < 2:
            continue
        col_str = oid_parts[0]
        row_index = ".".join(oid_parts[1:])

        if not wanted.get(col_str):
            continue

        row = rows.get(row_index, {})
        row[col_str] = value
        rows[row_index] = row

    return rows


def _parse_tables(ctx, host, community):
    new_rows = _walk_table(ctx, host, community, OID_NEW, ["2", "3", "4"])

    parsed = {}
    if len(new_rows) > 0:
        for row_index, row in new_rows.items():
            power_id = row.get("2", "")
            power_desc = row.get("3", "")
            power_state = row.get("4", "")
            if power_state != "1" and power_id:
                parsed[power_id] = {"desc": power_desc, "state": power_state}
    else:
        old_rows = _walk_table(ctx, host, community, OID_OLD, ["1", "2", "3"])
        for row_index, row in old_rows.items():
            power_id = row.get("1", "")
            power_desc = row.get("2", "")
            power_state = row.get("3", "")
            if power_state != "1" and power_id:
                parsed[power_id] = {"desc": power_desc, "state": power_state}

    return parsed


def _grade_state(power_state):
    if power_state == "2":
        return STATE_OK, "Power supply reports state: normal"
    if power_state == "3":
        return STATE_CRIT, "Power supply reports state: failure"
    if power_state == "1":
        return STATE_UNKNOWN, "Power supply reports state: other"
    return STATE_UNKNOWN, "Power supply reports an unknown state (%s)" % power_state


def _is_brocade_mlx(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return False
    val = res.stdout.strip().strip('"').strip("'")
    return val.startswith(MLX_SYS_OID_PREFIX)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_brocade_mlx(ctx, host, community):
            return {"changed": False, "msg": "not a Brocade MLX device", "data": {"discovery": []}}

        section = _parse_tables(ctx, host, community)
        discovery = []
        for power_id, info in section.items():
            discovery.append({
                "item": power_id,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    if not _is_brocade_mlx(ctx, host, community):
        return {
            "changed": False,
            "msg": "not a Brocade MLX device (no power supply data)",
            "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""},
        }

    section = _parse_tables(ctx, host, community)
    psu = section.get(item)
    if psu == None:
        return {
            "changed": False,
            "msg": "no such power supply: " + item,
            "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""},
        }

    state, msg = _grade_state(psu["state"])
    details = "power supply %s (%s): state %s" % (item, psu.get("desc", "?"), psu["state"])
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": details},
    }