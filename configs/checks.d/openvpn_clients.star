STATUS_PATHS = [
    "/var/log/openvpn/status.log",
    "/etc/openvpn/openvpn-status.log",
    "/var/run/openvpn/status.log",
    "/tmp/openvpn-status.log",
]

def _read_status(ctx, params):
    path = params.get("status_file", "")
    if path:
        if ctx.file_exists(path):
            return ctx.file_read(path)
        return ""
    for p in STATUS_PATHS:
        if ctx.file_exists(p):
            return ctx.file_read(p)
    return ""

def _parse_clients(content):
    clients = []
    in_list = False
    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith("Common Name,"):
            in_list = True
            continue
        if stripped.startswith("ROUTING TABLE") or stripped.startswith("GLOBAL STATS") or stripped == "END":
            in_list = False
            continue
        if in_list and "," in stripped:
            parts = stripped.split(",")
            if len(parts) >= 4:
                clients.append(parts)
    return clients

def main(ctx, params):
    content = _read_status(ctx, params)

    if params.get("_discover"):
        if not content:
            return {"changed": False, "msg": "no OpenVPN status file found",
                    "data": {"discovery": []}}
        clients = _parse_clients(content)
        discovery = []
        for c in clients:
            discovery.append({
                "item": c[0],
                "params": {"status_file": params.get("status_file", "")},
                "metrics": ["bytes_in", "bytes_out"],
            })
        return {"changed": False,
                "msg": "discovered %d OpenVPN clients" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    if not content:
        return {"changed": False, "msg": "OpenVPN status file not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    clients = _parse_clients(content)
    for c in clients:
        if c[0] == item:
            in_s = c[2].strip()
            out_s = c[3].strip()
            bytes_in = int(in_s) if in_s.isdigit() else 0
            bytes_out = int(out_s) if out_s.isdigit() else 0
            address = c[1].strip() if len(c) > 1 else "unknown"
            msg = "Channel is up, in: %d B, out: %d B" % (bytes_in, bytes_out)
            return {"changed": False, "msg": msg,
                    "data": {
                        "state": "OK",
                        "metrics": {"bytes_in": bytes_in, "bytes_out": bytes_out},
                        "details": "Address: %s" % address,
                    }}

    return {"changed": False, "msg": "Client connection not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}