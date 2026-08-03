def _compose_item(brrp_id):
    dot = brrp_id.find(".")
    if dot >= 0:
        return brrp_id[:dot]
    return brrp_id


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", params.get("snmp_host", "localhost"))
        community = params.get("community", "public")
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.272.4.40.1.1"],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no BRRP status data", "data": {"discovery": []}}

        discovered = []
        seen = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, value = parts[0], parts[1]
            suffix = oid[len(".1.3.6.1.4.1.272.4.40.1.1"):]
            dot_idx = suffix.find(".")
            if dot_idx < 0:
                continue
            brrp_id = suffix[dot_idx + 1:]
            item = _compose_item(brrp_id)
            if item not in seen:
                seen[item] = True
                discovered.append({"item": item, "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "")
    host = params.get("host", params.get("snmp_host", "localhost"))
    community = params.get("community", "public")

    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.272.4.40.1.1"],
        mutates=False,
    )
    if walk.rc != 0 or not walk.stdout.strip():
        return {
            "changed": False,
            "msg": "no BRRP status data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    statuses = {}
    for line in walk.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1]
        suffix = oid[len(".1.3.6.1.4.1.272.4.40.1.1"):]
        dot_idx = suffix.find(".")
        if dot_idx < 0:
            continue
        brrp_id = suffix[dot_idx + 1:]
        composed = _compose_item(brrp_id)
        if composed == item:
            statuses[composed] = value

    if item not in statuses:
        return {
            "changed": False,
            "msg": "Status for %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    brrp_status = statuses[item]
    if brrp_status == "1":
        message = "Status for %s is initialize" % item
        state = "WARN"
    elif brrp_status == "2":
        message = "Status for %s is backup" % item
        state = "OK"
    elif brrp_status == "3":
        message = "Status for %s is master" % item
        state = "OK"
    else:
        message = "Status for %s is at unknown value %s" % (item, brrp_status)
        state = "UNKNOWN"

    return {
        "changed": False,
        "msg": message,
        "data": {"state": state, "metrics": {}, "details": ""},
    }