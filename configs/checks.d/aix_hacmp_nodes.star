def _parse_cltopinfo(stdout):
    parsed = {}
    get_details = False
    node_name = ""
    network_name = ""

    for raw_line in stdout.splitlines():
        parts = raw_line.split()
        if len(parts) == 0:
            continue

        if len(parts) == 1:
            parsed[parts[0]] = {}

        elif len(parts) > 1 and "node" in parts[0].lower():
            candidate = parts[1].replace(":", "")
            if candidate in parsed:
                node_name = candidate
                network_name = ""
                get_details = True
            else:
                get_details = False

        elif "Interfaces" in parts[0] and get_details and len(parts) > 3:
            network_name = parts[3].replace(",", "")
            parsed[node_name][network_name] = []

        elif "Communication" in parts[0] and get_details and network_name != "" and len(parts) > 8:
            parsed[node_name][network_name].append({
                "name": parts[3].replace(",", ""),
                "attribute": parts[5].replace(",", ""),
                "ip_address": parts[8].replace(",", ""),
            })

    return parsed


def main(ctx, params):
    cltopinfo = "/usr/es/sbin/cluster/utilities/cltopinfo"

    if params.get("_discover"):
        if not ctx.file_exists(cltopinfo):
            return {"changed": False, "msg": "cltopinfo not found", "data": {"discovery": []}}
        res = ctx.run([cltopinfo], mutates=False)
        parsed = _parse_cltopinfo(res.stdout)
        items = [{"item": node, "params": {}, "metrics": []} for node in parsed]
        return {
            "changed": False,
            "msg": "discovered %d nodes" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    if not ctx.file_exists(cltopinfo):
        return {
            "changed": False,
            "msg": "cltopinfo not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "cltopinfo binary missing"},
        }

    res = ctx.run([cltopinfo], mutates=False)
    parsed = _parse_cltopinfo(res.stdout)

    data = parsed.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "node not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    summaries = []
    for net_name in data:
        infotext = "Network: " + net_name
        for iface in data[net_name]:
            infotext += (", interface: " + iface["name"] +
                         ", attribute: " + iface["attribute"] +
                         ", IP: " + iface["ip_address"])
        summaries.append(infotext)

    msg = "; ".join(summaries) if summaries else "no interfaces found"
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }