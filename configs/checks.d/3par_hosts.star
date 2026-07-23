def main(ctx, params):
    par_host = params.get("host", "localhost")
    port = params.get("port", 8080)
    username = params.get("username", "3paradm")
    password = params.get("password", "3pardata")

    base_url = "https://%s:%d/api/v1" % (par_host, port)

    auth_res = ctx.run([
        "curl", "-sk", "--max-time", "30", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", '{"user":"%s","password":"%s"}' % (username, password),
        base_url + "/credentials",
    ], mutates=False)

    if auth_res.rc != 0 or not auth_res.stdout:
        return {
            "changed": False,
            "msg": "3PAR API auth failed: " + auth_res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    auth_data = json.decode(auth_res.stdout)
    session_key = auth_data.get("key", "")
    if not session_key:
        return {
            "changed": False,
            "msg": "3PAR API returned no session key",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    hosts_res = ctx.run([
        "curl", "-sk", "--max-time", "30",
        "-H", "X-HP3PAR-WSAPI-SessionKey: " + session_key,
        "-H", "Accept: application/json",
        base_url + "/hosts",
    ], mutates=False)

    if hosts_res.rc != 0 or not hosts_res.stdout:
        return {
            "changed": False,
            "msg": "3PAR API hosts fetch failed: " + hosts_res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = json.decode(hosts_res.stdout)
    members = raw.get("members", [])

    hosts = {}
    for h in members:
        name = h.get("name")
        if name == None:
            continue
        descriptors = h.get("descriptors")
        os_val = descriptors.get("os") if descriptors != None else None
        hosts[name] = {
            "id": h.get("id", ""),
            "os": os_val,
            "fc_paths": len(h.get("FCPaths", [])),
            "iscsi_paths": len(h.get("iSCSIPaths", [])),
        }

    if params.get("_discover"):
        discovery = []
        for name in hosts:
            discovery.append({
                "item": name,
                "params": {},
                "metrics": ["fc_paths", "iscsi_paths"],
            })
        return {
            "changed": False,
            "msg": "discovered %d hosts" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    info = hosts.get(item)
    if info == None:
        return {
            "changed": False,
            "msg": "host not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parts = ["ID: %s" % str(info.get("id", ""))]

    os_name = info.get("os")
    if os_name:
        parts.append("OS: " + os_name)

    fc_paths = info.get("fc_paths", 0)
    iscsi_paths = info.get("iscsi_paths", 0)

    if fc_paths:
        parts.append("FC Paths: %d" % fc_paths)
    elif iscsi_paths:
        parts.append("iSCSI Paths: %d" % iscsi_paths)

    metrics = {}
    if fc_paths:
        metrics["fc_paths"] = fc_paths
    if iscsi_paths:
        metrics["iscsi_paths"] = iscsi_paths

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {"state": "OK", "metrics": metrics, "details": ""},
    }