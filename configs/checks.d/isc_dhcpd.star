# Translated Checkmk check: isc_dhcpd
# Read-only Starlark check module for the yolo-man agent.

def _ip_to_int(ip):
    parts = ip.split(".")
    return int(parts[0]) * 16777216 + int(parts[1]) * 65536 + int(parts[2]) * 256 + int(parts[3])

def _ip_in_range(ip_dec, start_dec, end_dec):
    return (start_dec <= ip_dec) and (ip_dec <= end_dec)

def _parse_dhcpd_file(ctx, path):
    pids = []
    pools = {}
    leases = []
    mode = ""
    if not ctx.file_exists(path):
        return pids, pools, leases
    content = ctx.file_read(path)
    for raw in content.split("\n"):
        line = raw.strip()
        if not line:
            continue
        if line in ["[general]", "[pools]", "[leases]"]:
            mode = line[1:-1]
            continue
        if mode == "general":
            if line.startswith("PID:"):
                parts = line.split()
                for p in parts[1:]:
                    v = p.strip()
                    if v != "" and v.lstrip("-").isdigit():
                        pids.append(int(v))
        elif mode == "pools":
            f = line.split()
            if len(f) < 2:
                continue
            if "bootp" in f[0]:
                f = f[1:]
            if len(f) < 2:
                continue
            start = f[0]
            end = f[1]
            item = start + "-" + end
            pools[item] = (start, end)
        elif mode == "leases":
            parts = line.split()
            v = ""
            if len(parts) >= 1:
                v = parts[0].strip()
            if v != "":
                leases.append(v)
    return pids, pools, leases

def main(ctx, params):
    path = "/etc/dhcp/dhcpd.conf"

    if params.get("_discover"):
        pids, pools, leases = _parse_dhcpd_file(ctx, path)
        out = []
        for item in pools:
            out.append({"item": item, "params": {"free_leases": (15.0, 5.0)}, "metrics": ["free_leases", "used_leases", "pct_used"]})
        return {"changed": False, "msg": "discovered %d dhcp pools" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    pids, pools, leases = _parse_dhcpd_file(ctx, path)

    if not pools:
        return {"changed": False, "msg": "no dhcp pools found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "dhcp server not configured on this host"}}

    if item not in pools:
        return {"changed": False, "msg": "no such pool: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    start, end = pools[item]
    start_dec = _ip_to_int(start)
    end_dec = _ip_to_int(end)
    num_leases = end_dec - start_dec + 1
    num_used = 0
    for lease_dec_str in leases:
        try_dec = _ip_to_int(lease_dec_str)
        if _ip_in_range(try_dec, start_dec, end_dec):
            num_used = num_used + 1
    if num_leases <= 0:
        return {"changed": False, "msg": "invalid pool range",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pct_used = (num_used * 100.0) / num_leases
    free_leases = num_leases - num_used
    metrics = {"free_leases": free_leases, "used_leases": num_used, "pct_used": pct_used}

    daemon_msg = ""
    levels = params.get("free_leases", (15.0, 5.0))
    warn = levels[0]
    crit = levels[1]
    state = "OK"
    if free_leases <= crit:
        state = "CRIT"
    elif free_leases <= warn:
        state = "WARN"
    if not pids:
        daemon_msg = " (DHCP daemon not running)"
    elif len(pids) > 1:
        daemon_msg = daemon_msg + " (dhcpd running %d times)" % len(pids)
    summary = "%s: %d/%d used (%f%%), %d free%s" % (item, num_used, num_leases, pct_used, free_leases, daemon_msg)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}