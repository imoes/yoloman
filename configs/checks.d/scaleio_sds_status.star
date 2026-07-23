def _parse_sds(stdout):
    section = {}
    sys_id = ""
    for line in stdout.splitlines():
        parts = line.split()
        if len(parts) == 0:
            continue
        if parts[0] == "SDS" and len(parts) >= 2:
            sys_id = parts[1].rstrip(":")
            if sys_id not in section:
                section[sys_id] = {}
        elif sys_id != "" and len(parts) >= 1:
            section[sys_id][parts[0]] = parts[1:]
    return section

def _overall_state(states):
    for s in states:
        if s == "CRIT":
            return "CRIT"
    for s in states:
        if s == "WARN":
            return "WARN"
    for s in states:
        if s == "UNKNOWN":
            return "UNKNOWN"
    return "OK"

def main(ctx, params):
    mdm_ip = params.get("mdm_ip", "")

    if mdm_ip != "":
        argv = ["scli", "--mdm_ip", mdm_ip, "--query_all_sds"]
    else:
        argv = ["scli", "--query_all_sds"]

    res = ctx.run(argv, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "scli failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    section = _parse_sds(res.stdout)

    if params.get("_discover"):
        items = []
        for sds_id in section:
            items.append({
                "item": sds_id,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d SDS" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "SDS not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    summary_parts = []
    states = []

    name_parts = data.get("NAME", [])
    pd_parts = data.get("PROTECTION_DOMAIN_ID", [])
    name = name_parts[0] if len(name_parts) > 0 else item
    pd_id = pd_parts[0] if len(pd_parts) > 0 else "unknown"
    summary_parts.append("Name: %s, PD: %s" % (name, pd_id))
    states.append("OK")

    state_parts = data.get("STATE", [])
    if len(state_parts) > 0:
        status = state_parts[0]
        if "normal" not in status.lower():
            summary_parts.append("State: " + status)
            states.append("CRIT")

    maint_parts = data.get("MAINTENANCE_MODE_STATE", [])
    if len(maint_parts) > 0:
        status_maint = maint_parts[0]
        if "no_maintenance" not in status_maint.lower():
            summary_parts.append("Maintenance: " + status_maint)
            states.append("WARN")

    conn_parts = data.get("MDM_CONNECTION_STATE", [])
    if len(conn_parts) > 0:
        status_conn = conn_parts[0]
        if "connected" not in status_conn.lower():
            summary_parts.append("Connection state: " + status_conn)
            states.append("CRIT")

    member_parts = data.get("MEMBERSHIP_STATE", [])
    if len(member_parts) > 0:
        status_member = member_parts[0]
        if "joined" not in status_member.lower():
            summary_parts.append("Membership state: " + status_member)
            states.append("CRIT")

    overall = _overall_state(states)

    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {"state": overall, "metrics": {}, "details": ""},
    }