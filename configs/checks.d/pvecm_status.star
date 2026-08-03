def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["pvecm", "status"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "pvecm not found", "data": {"discovery": [], "host_labels": {}}}
        if res.rc != 0:
            return {"changed": False, "msg": "pvecm status failed", "data": {"discovery": [], "host_labels": {}}}
        section = parse_section(res.stdout)
        if not section:
            return {"changed": False, "msg": "no cluster data", "data": {"discovery": [], "host_labels": {}}}
        return {
            "changed": False,
            "msg": "discovered PVE Cluster State",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ],
                "host_labels": {"cmk/os_family": ctx.facts().get("os_family", "")},
            },
        }

    res = ctx.run(["pvecm", "status"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "pvecm binary not found on this host", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        section = parse_section(res.stdout)
        if "cman_tool" in section and "cannot open connection to cman" in section.get("cman_tool", "").lower():
            return {"changed": False, "msg": "Cluster management tool: %s" % section.get("cman_tool", ""), "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "pvecm status failed: %s" % res.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = parse_section(res.stdout)
    if not section:
        return {"changed": False, "msg": "no cluster data found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if "cman_tool" in section and "cannot open connection to cman" in section.get("cman_tool", "").lower():
        return {"changed": False, "msg": "Cluster management tool: %s" % section.get("cman_tool", ""), "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    name = section.get("cluster name", section.get("quorum provider", "unknown"))
    nodes = section.get("nodes", "0")
    results = [{"state": "OK", "summary": "Name: %s, Nodes: %s" % (name, nodes)}]

    quorum = section.get("quorum", "")
    if "activity blocked" in quorum.lower():
        results.append({"state": "CRIT", "summary": "Quorum: %s" % quorum})

    expected = safe_int(section.get("expected votes", "0"))
    total = safe_int(section.get("total votes", "0"))
    if expected == total:
        results.append({"state": "OK", "summary": "No faults"})
    else:
        results.append({"state": "CRIT", "summary": "Expected votes: %s, Total votes: %s" % (section.get("expected votes", ""), section.get("total votes", ""))})

    worst = "OK"
    msgs = []
    for r in results:
        msgs.append(r["summary"])
        if r["state"] == "CRIT":
            worst = "CRIT"
        elif r["state"] == "WARN" and worst == "OK":
            worst = "WARN"

    return {"changed": False, "msg": "; ".join(msgs), "data": {"state": worst, "metrics": {}, "details": ""}}


def parse_section(stdout):
    parsed = {}
    for line in stdout.splitlines():
        parts = line.split(":", 1)
        if len(parts) < 2:
            continue
        k = parts[0].strip().lower()
        v = parts[1].strip()
        parsed.setdefault(k, v)
    return parsed


def safe_int(s):
    t = s.strip()
    if t.isdigit():
        return int(t)
    return 0