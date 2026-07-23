def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["pvecm", "nodes"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 nodes",
                    "data": {"discovery": []}}
        nodes = _discover_nodes(res.stdout)
        return {"changed": False, "msg": "discovered %d nodes" % len(nodes),
                "data": {"discovery": nodes}}
    item = params.get("item", "")
    res = ctx.run(["pvecm", "nodes"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "Node is missing",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    section = _parse_nodes(res.stdout)
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "Node is missing",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    state = "OK"
    msg_parts = ["ID: %s" % data.get("node_id", "")]
    if "status" in data:
        st = data["status"].lower()
        if st in _STATUS_MAP:
            state, status_text = _STATUS_MAP[st]
            msg_parts.append("Status: %s" % status_text)
        else:
            msg_parts.append("Status: unknown")
    if "joined" in data:
        msg_parts.append("Joined: %s" % data["joined"])
    if "votes" in data:
        msg_parts.append("Votes: %s" % data["votes"])
    return {"changed": False, "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {}, "details": ""}}


_STATUS_MAP = {
    "m": ("OK", "member of the cluster"),
    "x": ("WARN", "not a member of the cluster"),
    "d": ("CRIT", "known to the cluster but disallowed access to it"),
}


def _discover_nodes(output):
    lines = output.splitlines()
    header = None
    parse_func = None
    nodes = []
    for line in lines:
        stripped = line.strip()
        if stripped == "Node Sts Inc Joined Name":
            header = ["node_id", "status", "joined", "name"]
            parse_func = _parse_line_v2
            continue
        if stripped == "Nodeid Votes Name":
            header = ["node_id", "votes", "name"]
            parse_func = _parse_line_gt_2
            continue
        if stripped == "Nodeid Votes Qdevice Name":
            header = ["node_id", "votes", "qdevice", "name"]
            parse_func = _parse_line_gt_2_qdevice
            continue
        if header == None or parse_func == None:
            continue
        item, _ = parse_func(stripped.split(), header)
        if item:
            nodes.append({"item": item, "params": {}, "metrics": []})
    return nodes


def _parse_nodes(output):
    lines = output.splitlines()
    header = None
    parse_func = None
    section = {}
    for line in lines:
        stripped = line.strip()
        if stripped == "Node Sts Inc Joined Name":
            header = ["node_id", "status", "joined", "name"]
            parse_func = _parse_line_v2
            continue
        if stripped == "Nodeid Votes Name":
            header = ["node_id", "votes", "name"]
            parse_func = _parse_line_gt_2
            continue
        if stripped == "Nodeid Votes Qdevice Name":
            header = ["node_id", "votes", "qdevice", "name"]
            parse_func = _parse_line_gt_2_qdevice
            continue
        if header == None or parse_func == None:
            continue
        item, data = parse_func(stripped.split(), header)
        if item:
            section.setdefault(item, data)
    return section


def _parse_line_v2(fields, header):
    if len(fields) == 6:
        data = {"node_id": fields[0], "status": fields[1],
                "joined": " ".join(fields[3:5])}
    else:
        data = {"node_id": fields[0], "status": fields[1]}
    name = fields[-1]
    return name, data


def _parse_line_gt_2(fields, header):
    name = " ".join(fields[2:])
    data = {"node_id": fields[0], "votes": fields[1]}
    return name, data


def _parse_line_gt_2_qdevice(fields, header):
    if len(fields) > 3:
        name = " ".join(fields[3:])
    else:
        name = fields[2] if len(fields) > 2 else "QDevice"
    data = {"node_id": fields[0], "votes": fields[1], "qdevice": fields[2]}
    return name, data