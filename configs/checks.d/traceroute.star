# Checkmk active check: traceroute
# Translated to read-only Starlark check module for yolo-man agent

DEFAULT_PROBE_METHOD = "udp"
DEFAULT_DNS = False
DEFAULT_ADDRESS_FAMILY = None
DEFAULT_ROUTERS = []

def _build_traceroute_args(params, host):
    args = [host]

    if params.get("dns", DEFAULT_DNS):
        args.append("--use_dns")

    method = params.get("method", DEFAULT_PROBE_METHOD)
    if method == None or method == "":
        method = DEFAULT_PROBE_METHOD
    args.append("--probe_method=%s" % method)

    af = params.get("address_family", DEFAULT_ADDRESS_FAMILY)
    if af == None or af == "":
        af = "ipv4"
    args.append("--ip_address_family=%s" % af)

    routers = params.get("routers", DEFAULT_ROUTERS)

    missing_warn = [r for r, s in routers if s == "W"]
    missing_crit = [r for r, s in routers if s == "C"]
    found_warn = [r for r, s in routers if s == "w"]
    found_crit = [r for r, s in routers if s == "c"]

    if len(missing_warn) > 0:
        args.append("--routers_missing_warn")
        args.extend(missing_warn)
    if len(missing_crit) > 0:
        args.append("--routers_missing_crit")
        args.extend(missing_crit)
    if len(found_warn) > 0:
        args.append("--routers_found_warn")
        args.extend(found_warn)
    if len(found_crit) > 0:
        args.append("--routers_found_crit")
        args.extend(found_crit)

    return args

def _parse_hops(stdout):
    hops = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        parts = stripped.split()
        if len(parts) < 2:
            continue
        first = parts[0]
        if not first.isdigit():
            continue
        hop_num = int(first)
        if hop_num < 1:
            continue
        hop_name = parts[1]
        addr = hop_name
        if hop_name.startswith("(") and hop_name.endswith(")"):
            addr = hop_name[1:-1]
        hops.append(addr)
    return hops

def _grade(hops, params):
    routers = params.get("routers", DEFAULT_ROUTERS)
    missing_warn = [r for r, s in routers if s == "W"]
    missing_crit = [r for r, s in routers if s == "C"]
    found_warn = [r for r, s in routers if s == "w"]
    found_crit = [r for r, s in routers if s == "c"]

    hop_set = set(hops)

    states = []

    for r in missing_warn:
        if r not in hop_set:
            states.append("WARN")
    for r in missing_crit:
        if r not in hop_set:
            states.append("CRIT")
    for r in found_warn:
        if r in hop_set:
            states.append("WARN")
    for r in found_crit:
        if r in hop_set:
            states.append("CRIT")

    if len(states) == 0:
        return "OK"
    if "CRIT" in states:
        return "CRIT"
    if "WARN" in states:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        version_res = ctx.run(["traceroute", "--version"], mutates=False)
        if version_res.rc == 127:
            return {"changed": False, "msg": "traceroute not installed", "data": {"discovery": []}}
        if not ctx.file_exists("/usr/bin/traceroute") and not ctx.file_exists("/bin/traceroute") and not ctx.file_exists("/usr/sbin/traceroute") and not ctx.file_exists("/sbin/traceroute"):
            return {"changed": False, "msg": "traceroute not installed", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered Routing", "data": {"discovery": [{"item": "", "params": {"warn": 80, "crit": 90}, "metrics": []}]}}

    host = params.get("host", params.get("target", "localhost"))
    dns = params.get("dns", DEFAULT_DNS)
    method = params.get("method", DEFAULT_PROBE_METHOD)
    address_family = params.get("address_family", DEFAULT_ADDRESS_FAMILY)
    routers = params.get("routers", DEFAULT_ROUTERS)

    args = _build_traceroute_args(params, host)
    cmd = ["traceroute"]
    cmd.extend(args)
    res = ctx.run(cmd, mutates=False)

    if res.rc == 127:
        return {"changed": False, "msg": "traceroute not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": "traceroute binary not found"}}

    if res.rc != 0 and res.stdout == "":
        return {"changed": False, "msg": "traceroute failed: " + res.stderr.strip(), "data": {"state": "UNKNOWN", "metrics": {}, "details": "traceroute execution failed"}}

    hops = _parse_hops(res.stdout)
    state = _grade(hops, params)

    msg_parts = []
    msg_parts.append("host: %s" % host)
    msg_parts.append("hops: %d" % len(hops))
    if len(hops) > 0:
        msg_parts.append("last: %s" % hops[-1])

    detail_lines = ["Traceroute to %s:" % host]
    for i, h in enumerate(hops):
        detail_lines.append("  %d. %s" % (i + 1, h))
    details = "\n".join(detail_lines)

    metrics = {}

    return {"changed": False, "msg": ", ".join(msg_parts), "data": {"state": state, "metrics": metrics, "details": details}}