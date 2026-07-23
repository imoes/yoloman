DFLT_HEADER = [
    "id",
    "port_id",
    "port_speed",
    "node_id",
    "node_name",
    "WWPN",
    "status",
    "switch_WWPN",
    "attachment",
    "type",
    "adapter_location",
    "adapter_port_id",
]

def _parse_svc_output(stdout):
    parsed_by_id = {}
    header = DFLT_HEADER
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if " command not found" in line:
            continue
        parts = line.split(":")
        if not parts:
            continue
        first = parts[0]
        if first in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = parts
            continue
        row = {}
        for i, key in enumerate(header[1:]):
            idx = i + 1
            row[key] = parts[idx] if idx < len(parts) else ""
        if first not in parsed_by_id:
            parsed_by_id[first] = []
        parsed_by_id[first].append(row)

    result = {}
    for id_val in parsed_by_id:
        rows = parsed_by_id[id_val]
        if not rows:
            continue
        data = rows[0]
        node_id = data.get("node_id", "")
        adapter_location = data.get("adapter_location", "")
        adapter_port_id = data.get("adapter_port_id", "")
        if node_id and adapter_location and adapter_port_id:
            item_name = "Node %s Slot %s Port %s" % (node_id, adapter_location, adapter_port_id)
        else:
            item_name = "Port %s" % id_val
        if item_name not in result:
            result[item_name] = data
    return result

def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "admin")

    res = ctx.run(
        [
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "%s@%s" % (user, host),
            "lssasport", "-delim", ":",
        ],
        mutates=False,
    )

    if res.rc != 0:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "lssasport failed: " + res.stderr,
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "lssasport failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    section = _parse_svc_output(res.stdout)

    if params.get("_discover"):
        out = []
        for item_name in section:
            data = section[item_name]
            status = data.get("status", "")
            if status == "offline_unconfigured":
                continue
            out.append({
                "item": item_name,
                "params": {"current_state": status},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d SAS ports" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    data = section.get(item)

    if data == None:
        return {
            "changed": False,
            "msg": "SAS port not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sasport_status = data.get("status", "")
    current_state = params.get("current_state", "offline")
    port_speed = data.get("port_speed", "N/A")
    port_type = data.get("type", "")

    state = "OK" if sasport_status == current_state else "CRIT"
    msg = "Status: %s, Speed: %s, Type: %s" % (sasport_status, port_speed, port_type)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }