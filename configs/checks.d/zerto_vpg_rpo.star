# ===== check plugin: cmk/plugins/zerto/agent_based/zerto_vpg_rpo.py =====

MAP_RPO_STATES = {
    "0": ("WARN", "VPG is initializing"),
    "1": ("OK", "Meeting SLA specification"),
    "2": ("CRIT", "Not meeting SLA specification for RPO SLA and journal history"),
    "3": ("CRIT", "Not meeting SLA specification for RPO SLA"),
    "4": ("CRIT", "Not meeting SLA specification for journal history"),
    "5": ("WARN", "VPG is in a failover operation"),
    "6": ("WARN", "VPG is in a move operation"),
    "7": ("WARN", "VPG is being deleted"),
    "8": ("WARN", "VPG has been recovered"),
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cmk", "invoke-agent", "--section-name", "zerto_vpg_rpo"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no data from agent section zerto_vpg_rpo",
                    "data": {"discovery": []}}
        # Agent section output: one line per VPG: <name> <state> <actual_rpo>
        discovered = []
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 3:
                vpgname = parts[0]
                state = parts[1]
                # Suggest default params (none needed for this check)
                discovered.append({"item": vpgname, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d VPGs" % len(discovered),
                "data": {"discovery": discovered}}

    # Check mode: one item
    item = params.get("item", "")
    res = ctx.run(["cmk", "invoke-agent", "--section-name", "zerto_vpg_rpo"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data from agent section zerto_vpg_rpo",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vpg_data = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3:
            vpgname = parts[0]
            vpg_data.setdefault(vpgname, {"state": parts[1], "actual_rpo": parts[2]})

    data = vpg_data.get(item)
    if data == None:
        return {"changed": False, "msg": "VPG not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_key = data.get("state", "")
    state_str, summary = MAP_RPO_STATES.get(state_key, ("UNKNOWN", "Unknown"))
    return {"changed": False, "msg": "VPG Status: %s" % summary,
            "data": {"state": state_str, "metrics": {}, "details": ""}}
