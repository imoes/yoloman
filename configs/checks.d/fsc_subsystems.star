def _snmp_get_str(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.skipped:
        return ""
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _snmp_walk(ctx, community, host, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.skipped:
        return ""
    if res.rc != 0:
        return ""
    return res.stdout

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base_oid = ".1.3.6.1.4.1.231.2.10.2.11.3.1.1"
    col_name = base_oid + ".2"
    col_status = base_oid + ".3"

    if params.get("_discover"):
        sys_descr = _snmp_get_str(ctx, community, host, ".1.3.6.1.2.1.1.1.0")
        if sys_descr == "" or sys_descr.find("Fujitsu") == -1 and sys_descr.find("FSC") == -1:
            return {"changed": False, "msg": "no FSC/SNMP subsystem source found", "data": {"discovery": []}}

        walk_out = _snmp_walk(ctx, community, host, col_name)
        if walk_out == "":
            return {"changed": False, "msg": "no FSC subsystems found", "data": {"discovery": []}}

        discovery = []
        for line in walk_out.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            name = parts[1].strip()
            if oid_full.find(col_name + ".") != 0:
                continue
            index = oid_full[len(col_name) + 1:]
            status = _snmp_get_str(ctx, community, host, col_status + "." + index)
            status_int = 0
            if status != "" and status.isdigit():
                status_int = int(status)
            if status_int > 0:
                discovery.append({
                    "item": name,
                    "params": {},
                    "metrics": ["status"]
                })
        return {
            "changed": False,
            "msg": "discovered %d FSC subsystems" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    walk_out = _snmp_walk(ctx, community, host, col_name)
    if walk_out == "":
        return {
            "changed": False,
            "msg": "no FSC subsystems reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    target_index = None
    for line in walk_out.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        name = parts[1].strip()
        if oid_full.find(col_name + ".") != 0:
            continue
        if name == item:
            target_index = oid_full[len(col_name) + 1:]
            break

    if target_index == None:
        return {
            "changed": False,
            "msg": "subsystem %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status_str = _snmp_get_str(ctx, community, host, col_status + "." + target_index)
    if status_str == "" or not status_str.isdigit():
        return {
            "changed": False,
            "msg": "status not found in SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status = int(status_str)
    statusname = {1: "ok", 2: "degraded", 3: "error", 4: "failed", 5: "unknown-init"}.get(status, "invalid")

    state = "UNKNOWN"
    summary = ""
    if status in (1, 5):
        state = "OK"
        summary = "%s - no problems" % statusname
    elif 2 <= status and status <= 4:
        state = "CRIT"
        summary = statusname
    else:
        state = "UNKNOWN"
        summary = "unknown status %d" % status

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {"status": status}, "details": ""}
    }