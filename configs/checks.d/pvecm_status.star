def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["pvecm", "status"], mutates=False)
        section = parse_pvecm_status(res.stdout.splitlines() if res.stdout else [])
        if section:
            return {
                "changed": False,
                "msg": "discovered service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {
            "changed": False,
            "msg": "no pvecm status data",
            "data": {"discovery": []},
        }

    # check mode (single service item is always "")
    res = ctx.run(["pvecm", "status"], mutates=False)
    section = parse_pvecm_status(res.stdout.splitlines() if res.stdout else [])

    if "cman_tool" in section and "cannot open connection to cman" in section["cman_tool"].lower():
        return {
            "changed": False,
            "msg": "Cluster management tool: %s" % section["cman_tool"],
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    name = section.get("cluster name", section.get("quorum provider", "unknown"))
    nodes = section.get("nodes", "0")
    quorum = section.get("quorum", "")
    expected_votes = section.get("expected votes", "")
    total_votes = section.get("total votes", "")

    state = "OK"
    msg_parts = ["Name: %s, Nodes: %s" % (name, nodes)]

    if "activity blocked" in quorum.lower():
        state = "CRIT"
        msg_parts.append("Quorum: %s" % quorum)

    # Guarded conversion to int — if either is empty/non-digit, skip vote comparison
    if expected_votes.isdigit() and total_votes.isdigit():
        ev = int(expected_votes)
        tv = int(total_votes)
        if ev != tv:
            state = "CRIT"
            msg_parts.append("Expected votes: %s, Total votes: %s" % (expected_votes, total_votes))
        else:
            msg_parts.append("No faults")

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {"state": state, "metrics": {}, "details": ""},
    }


def parse_pvecm_status(lines):
    parsed = {}
    for line in lines:
        if len(line.strip()) == 0:
            continue
        idx = line.find(":")
        if idx == -1:
            continue
        key = line[:idx].strip().lower()
        value = line[idx+1:].strip()
        parsed.setdefault(key, value)
    return parsed
