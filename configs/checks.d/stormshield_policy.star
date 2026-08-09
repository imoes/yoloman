BASE_OID = ".1.3.6.1.4.1.11256.1.8.1.1"
COL_POLICY_NAME = "2"
COL_SLOT_NAME = "3"
COL_SYNC_STATUS = "5"

SYNC_STATUS_MAP = {
    "1": "synced",
    "2": "not synced",
}

def _snmp_value(raw):
    colon = raw.find(": ")
    if colon >= 0:
        v = raw[colon + 2:].strip()
    else:
        v = raw.strip()
    if v.startswith('"') and v.endswith('"'):
        v = v[1:-1]
    return v

def _fetch_table(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID],
        mutates=False,
    )
    rows = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        eq = line.find(" = ")
        if eq < 0:
            continue
        oid = line[:eq].strip()
        raw_val = line[eq + 3:]
        value = _snmp_value(raw_val)
        for col in [COL_POLICY_NAME, COL_SLOT_NAME, COL_SYNC_STATUS]:
            col_prefix = BASE_OID + "." + col + "."
            if oid.startswith(col_prefix):
                idx = oid[len(col_prefix):]
                if idx not in rows:
                    rows[idx] = {}
                rows[idx][col] = value
    return rows

def main(ctx, params):
    if params.get("_discover"):
        rows = _fetch_table(ctx, params)
        items = []
        for idx in sorted(rows.keys()):
            row = rows[idx]
            policy_name = row.get(COL_POLICY_NAME, "")
            if policy_name != "":
                items.append({
                    "item": policy_name,
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d policies" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    rows = _fetch_table(ctx, params)

    for idx in sorted(rows.keys()):
        row = rows[idx]
        policy_name = row.get(COL_POLICY_NAME, "")
        if policy_name != item:
            continue
        slot_name = row.get(COL_SLOT_NAME, "")
        sync_status = row.get(COL_SYNC_STATUS, "")
        label = SYNC_STATUS_MAP.get(sync_status, "unknown (%s)" % sync_status)
        state = "OK" if sync_status == "1" else "CRIT"
        msg = "Policy is %s" % label
        if slot_name != "":
            msg = msg + ", Slot Name: " + slot_name
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state,
                "metrics": {},
                "details": "",
            },
        }

    return {
        "changed": False,
        "msg": "Policy %s not found" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }