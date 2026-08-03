def _parse_section(res):
    header = [
        "id",
        "name",
        "port_count",
        "iogrp_count",
        "status",
        "site_id",
        "site_name",
        "host_cluster_id",
        "host_cluster_name",
    ]
    parsed = {}
    for line in res.stdout.splitlines():
        fields = line.split(":")
        if len(fields) < 2:
            continue
        if fields[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = fields
            continue
        row_id = fields[0]
        data = dict(zip(header[1:], fields[1:]))
        parsed.setdefault(row_id, []).append(data)
    return parsed


def _grade_count(value, levels, is_lower):
    if levels == None:
        return "OK"
    warn, crit = levels[0], levels[1]
    if is_lower:
        if value <= crit:
            return "CRIT"
        if value <= warn:
            return "WARN"
        return "OK"
    else:
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
        return "OK"


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["svcinfo", "lsthost", "-nohdr", "-quiet"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "IBM SVC not present", "data": {"discovery": [], "host_labels": {}}}
        section = _parse_section(res)
        if len(section) == 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": [], "host_labels": {}}}
        metrics = ["active", "inactive", "degraded", "offline", "other"]
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": metrics}], "host_labels": {}},
        }

    item = params.get("item", "")
    res = ctx.run(["svcinfo", "lsthost", "-nohdr", "-quiet"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "IBM SVC host data ungatherable (rc=%d)" % res.rc,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    section = _parse_section(res)
    if len(section) == 0:
        return {
            "changed": False,
            "msg": "no IBM SVC hosts found",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    degraded = 0
    offline = 0
    active = 0
    inactive = 0
    other = 0
    for rows in section.values():
        for data in rows:
            status = data.get("status", "")
            if status == "degraded":
                degraded += 1
            elif status == "offline":
                offline += 1
            elif status in ["active", "online"]:
                active += 1
            elif status == "inactive":
                inactive += 1
            else:
                other += 1

    states = []
    states.append(_grade_count(active, params.get("active_hosts"), True))
    states.append(_grade_count(inactive, params.get("inactive_hosts"), False))
    states.append(_grade_count(degraded, params.get("degraded_hosts"), False))
    states.append(_grade_count(offline, params.get("offline_hosts"), False))
    states.append(_grade_count(other, params.get("other_hosts"), False))

    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"
    else:
        state = "OK"

    metrics = {
        "active": active,
        "inactive": inactive,
        "degraded": degraded,
        "offline": offline,
        "other": other,
    }

    details = "%d active, %d inactive, %d degraded, %d offline, %d other" % (
        active,
        inactive,
        degraded,
        offline,
        other,
    )

    return {
        "changed": False,
        "msg": details,
        "data": {"state": state, "metrics": metrics, "details": details},
    }