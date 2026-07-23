def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}
    host = params.get("host") or ""
    port = int(params.get("port") or 22)
    timeout_s = int(params.get("timeout_s") or 10)
    probe = ctx.probe("tcp", {"host": host, "port": port, "timeout_s": timeout_s})
    if probe.get("error"):
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": probe["error"]}}
    if not probe.get("connected"):
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": "Connection refused on port %d" % port}}
    connect_ms = float(probe.get("connect_ms") or 0)
    banner = probe.get("received") or ""
    remote_protocol_actual = ""
    remote_version_actual = ""
    if banner.startswith("SSH-"):
        rest = banner[4:]
        dash_idx = rest.find("-")
        if dash_idx >= 0:
            remote_protocol_actual = rest[:dash_idx]
            rest2 = rest[dash_idx + 1:]
            end_idx = len(rest2)
            for ch in [" ", "\r", "\n"]:
                idx = rest2.find(ch)
                if idx >= 0 and idx < end_idx:
                    end_idx = idx
            remote_version_actual = rest2[:end_idx]
    state = "OK"
    problems = []
    expected_version = params.get("remote_version")
    if expected_version != None and expected_version != "":
        if expected_version not in remote_version_actual:
            state = "WARN"
            problems.append("version mismatch: got %s expected %s" % (remote_version_actual, expected_version))
    expected_protocol = params.get("remote_protocol")
    if expected_protocol != None and expected_protocol != "":
        if expected_protocol != remote_protocol_actual:
            state = "WARN"
            problems.append("protocol mismatch: got %s expected %s" % (remote_protocol_actual, expected_protocol))
    detail = "SSH %s-%s, %d ms" % (remote_protocol_actual, remote_version_actual, int(connect_ms))
    if problems:
        detail += " | " + "; ".join(problems)
    return {"changed": False, "msg": state, "data": {"state": state, "metrics": {"connect_ms": connect_ms}, "details": detail}}
