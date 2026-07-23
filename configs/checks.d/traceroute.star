def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}
    host = params.get("host") or ""
    if not host:
        return {"changed": False, "msg": "UNKNOWN", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no host configured"}}
    dns = params.get("dns") or False
    method = params.get("method") or "udp"
    ip_family = params.get("ip_address_family") or "ipv4"
    argv = ["traceroute"]
    if ip_family == "ipv6":
        argv.append("-6")
    else:
        argv.append("-4")
    if not dns:
        argv.append("-n")
    if method == "icmp":
        argv.append("-I")
    elif method == "tcp":
        argv.append("-T")
    argv.extend(["-w", "3", "-m", "30"])
    argv.append(host)
    result = ctx.run(argv, ok_codes=[0, 1, 2])
    if result.rc not in [0, 1, 2]:
        detail = result.stderr or result.stdout or ("traceroute exited %d" % result.rc)
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": detail}}
    output = result.stdout or ""
    found_routers = []
    hop_count = 0
    for line in output.split("\n"):
        line = line.strip()
        if not line or line.startswith("traceroute"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        hop_count += 1
        addr = parts[1]
        if addr != "*" and addr not in found_routers:
            found_routers.append(addr)
        for part in parts:
            if part.startswith("(") and part.endswith(")") and len(part) > 2:
                ip = part[1:-1]
                if ip not in found_routers:
                    found_routers.append(ip)
    routers_missing_warn = params.get("routers_missing_warn") or []
    routers_missing_crit = params.get("routers_missing_crit") or []
    routers_found_warn = params.get("routers_found_warn") or []
    routers_found_crit = params.get("routers_found_crit") or []
    state = "OK"
    problems = []
    for r in routers_missing_crit:
        if r not in found_routers:
            state = "CRIT"
            problems.append("missing CRIT: %s" % r)
    for r in routers_missing_warn:
        if r not in found_routers:
            if state == "OK":
                state = "WARN"
            problems.append("missing WARN: %s" % r)
    for r in routers_found_crit:
        if r in found_routers:
            state = "CRIT"
            problems.append("unexpected CRIT: %s" % r)
    for r in routers_found_warn:
        if r in found_routers:
            if state == "OK":
                state = "WARN"
            problems.append("unexpected WARN: %s" % r)
    detail = "traceroute %s: %d hops" % (host, hop_count)
    if problems:
        detail += " | " + "; ".join(problems)
    return {"changed": False, "msg": state, "data": {"state": state, "metrics": {"hops": hop_count}, "details": detail}}
