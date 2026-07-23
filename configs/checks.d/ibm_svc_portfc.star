DFLT_HEADER = [
    "id",
    "fc_io_port_id",
    "port_id",
    "type",
    "port_speed",
    "node_id",
    "node_name",
    "WWPN",
    "nportid",
    "status",
    "attachment",
    "cluster_use",
    "adapter_location",
    "adapter_port_id",
]

HEADER_IDS = ["id", "node_id", "mdisk_id", "enclosure_id"]

def _parse_portfc(stdout):
    header = DFLT_HEADER
    parsed = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if "command not found" in line:
            continue
        fields = line.split(":")
        if len(fields) < 2:
            continue
        first = fields[0]
        if first in HEADER_IDS:
            header = fields
            continue
        id_ = first
        col_names = header[1:]
        data = {}
        for i in range(len(col_names)):
            if i + 1 < len(fields):
                data[col_names[i]] = fields[i + 1]
        node_id = data.get("node_id", "")
        adapter_location = data.get("adapter_location", "")
        adapter_port_id = data.get("adapter_port_id", "")
        if node_id and adapter_location and adapter_port_id:
            item_name = "Node %s Slot %s Port %s" % (node_id, adapter_location, adapter_port_id)
        else:
            item_name = "Port %s" % id_
        if item_name not in parsed:
            parsed[item_name] = data
    return parsed

def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "admin")
    ssh_key = params.get("ssh_key", "")

    ssh_base = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"]
    if ssh_key:
        ssh_base = ssh_base + ["-i", ssh_key]
    ssh_args = ssh_base + [user + "@" + host, "lsportfc", "-delim", ":"]

    res = ctx.run(ssh_args, mutates=False)
    if res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "lsportfc failed: " + res.stderr,
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "lsportfc failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = _parse_portfc(res.stdout)

    if params.get("_discover"):
        items = []
        for item_name, data in parsed.items():
            if data.get("status", "") != "active":
                continue
            items.append({"item": item_name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d FC ports" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    data = parsed.get(item)
    if data == None:
        return {"changed": False, "msg": "FC port not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    port_status = data.get("status", "unknown")
    port_speed = data.get("port_speed", "N/A")
    wwpn = data.get("WWPN", "N/A")

    state = "OK" if port_status == "active" else "CRIT"
    msg = "Status: %s, Speed: %s, WWPN: %s" % (port_status, port_speed, wwpn)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}