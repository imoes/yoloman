# Mapping of raidStatus integer to (summary, State) as per source
_RSTATES = {
    1:  ("OK", "OK"),
    2:  ("repairing", "WARN"),
    3:  ("migrating", "WARN"),
    4:  ("expanding", "WARN"),
    5:  ("deleting", "WARN"),
    6:  ("creating", "WARN"),
    7:  ("RAID syncing", "OK"),
    8:  ("RAID parity checking", "OK"),
    9:  ("RAID assembling", "WARN"),
    10: ("cancelling", "WARN"),
    11: ("degraded", "CRIT"),
    12: ("crashed", "CRIT"),
    13: ("scrubbing", "OK"),
    14: ("RAID deploying", "OK"),
    15: ("RAID undeploying", "OK"),
    16: ("RAID mounting cache", "OK"),
    17: ("RAID unmounting cache", "OK"),
    18: ("RAID continue expanding", "WARN"),
    19: ("RAID converting", "OK"),
    20: ("RAID migrating", "OK"),
    21: ("RAID status unknown", "UNKNOWN"),
}

def _snmp_value_to_str(val):
    if val == None:
        return ""
    v = val.strip()
    if len(v) >= 2 and v[0] == "\"" and v[-1] == "\"":
        return v[1:-1]
    return v

def _walk_oid(ctx, base_oid, suffix, community, host):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community,
                   "-On", host,
                   base_oid + "." + suffix], mutates=False)
    out = {}
    for line in res.stdout.splitlines():
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        leaf = oid_full.rsplit(".", 1)
        if len(leaf) != 2:
            continue
        idx = leaf[1]
        val_str = _snmp_value_to_str(parts[1])
        out[idx] = val_str
    return out

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        names = _walk_oid(ctx, ".1.3.6.1.4.1.6574.3.1.1", "2", community, host)
        statuses = _walk_oid(ctx, ".1.3.6.1.4.1.6574.3.1.1", "3", community, host)
        items = []
        for idx in names:
            if idx in statuses and names[idx] != "":
                items.append({
                    "item": names[idx],
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d RAID volumes" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    names = _walk_oid(ctx, ".1.3.6.1.4.1.6574.3.1.1", "2", community, host)
    statuses = _walk_oid(ctx, ".1.3.6.1.4.1.6574.3.1.1", "3", community, host)

    idx = ""
    for k in names:
        if names[k] == item and k in statuses:
            idx = k
            break

    if idx == "":
        return {
            "changed": False,
            "msg": "RAID volume not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    raw_status = statuses.get(idx, "")
    if raw_status == "" or not raw_status.isdigit():
        return {
            "changed": False,
            "msg": "RAID status unreadable for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status_int = int(raw_status)
    if not status_int in _RSTATES:
        return {
            "changed": False,
            "msg": "Unknown RAID status code %d for %s" % (status_int, item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    summary, state = _RSTATES[status_int]
    return {
        "changed": False,
        "msg": "Status: " + summary,
        "data": {"state": state, "metrics": {}, "details": ""}
    }