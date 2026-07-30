CONF_PATHS = [
    "/etc/dhcp/dhcpd.conf",
    "/etc/dhcpd.conf",
    "/usr/local/etc/dhcpd.conf",
]

LEASE_PATHS = [
    "/var/lib/dhcpd/dhcpd.leases",
    "/var/lib/dhcp/dhcpd.leases",
    "/var/lib/dhcpd.leases",
    "/var/db/dhcpd.leases",
]

STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": -1}

def ip_to_int(ip):
    parts = ip.strip().split(".")
    if len(parts) != 4:
        return -1
    n = 0
    for part in parts:
        if not part.isdigit():
            return -1
        n = n * 256 + int(part)
    return n

def find_path(ctx, candidates):
    for path in candidates:
        if ctx.file_exists(path):
            return path
    return None

def parse_pools(content):
    pools = []
    for line in content.splitlines():
        stripped = line.strip().rstrip(";")
        if not stripped.startswith("range"):
            continue
        parts = stripped.split()
        if len(parts) < 3:
            continue
        rest = parts[1:]
        if len(rest) >= 1 and "bootp" in rest[0]:
            rest = rest[1:]
        if len(rest) < 2:
            continue
        start = rest[0]
        end = rest[1]
        if ip_to_int(start) < 0 or ip_to_int(end) < 0:
            continue
        pools.append({"item": start + "-" + end, "start": start, "end": end})
    return pools

def parse_leases(content):
    lease_states = {}
    current_ip = None
    in_lease = False
    is_active = False
    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith("lease ") and stripped.endswith("{"):
            parts = stripped.split()
            if len(parts) >= 2:
                current_ip = parts[1]
                in_lease = True
                is_active = False
        elif in_lease and "binding state active" in stripped:
            is_active = True
        elif in_lease and stripped == "}":
            if current_ip != None:
                lease_states[current_ip] = "active" if is_active else "free"
            in_lease = False
            current_ip = None
            is_active = False
    return [ip for ip, st in lease_states.items() if st == "active"]

def get_dhcpd_pids(ctx):
    res = ctx.run(["pgrep", "-x", "dhcpd"], mutates=False, ok_codes=[0, 1, 127])
    if res.rc == 0:
        return [p.strip() for p in res.stdout.strip().splitlines() if p.strip()]
    if res.rc == 1:
        return []
    ps_res = ctx.run(["ps", "-e", "-o", "pid,comm"], mutates=False)
    pids = []
    for line in ps_res.stdout.splitlines()[1:]:
        parts = line.strip().split()
        if len(parts) >= 2 and parts[1] == "dhcpd":
            pids.append(parts[0])
    return pids

def main(ctx, params):
    conf_path = find_path(ctx, CONF_PATHS)

    if params.get("_discover"):
        if conf_path == None:
            return {
                "changed": False,
                "msg": "discovered 0 pools",
                "data": {"discovery": []},
            }
        pools = parse_pools(ctx.file_read(conf_path))
        discovery = [
            {
                "item": p["item"],
                "params": {"free_leases": [15.0, 5.0]},
                "metrics": ["free_leases", "used_leases", "total_leases"],
            }
            for p in pools
        ]
        return {
            "changed": False,
            "msg": "discovered %d pools" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    pids = get_dhcpd_pids(ctx)

    daemon_state = "OK"
    daemon_msg = ""
    if len(pids) == 0:
        daemon_state = "CRIT"
        daemon_msg = "DHCP Daemon not running"
    elif len(pids) > 1:
        daemon_state = "WARN"
        daemon_msg = "DHCP Daemon running %d times (PIDs: %s)" % (len(pids), ", ".join(pids))

    if conf_path == None:
        final_state = "CRIT" if daemon_state == "CRIT" else "UNKNOWN"
        msg = daemon_msg if daemon_msg else "dhcpd.conf not found"
        return {
            "changed": False,
            "msg": msg,
            "data": {"state": final_state, "metrics": {}, "details": ""},
        }

    pools = parse_pools(ctx.file_read(conf_path))
    pool = None
    for p in pools:
        if p["item"] == item:
            pool = p
            break

    if pool == None:
        return {
            "changed": False,
            "msg": "Pool %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    start_int = ip_to_int(pool["start"])
    end_int = ip_to_int(pool["end"])
    total_leases = end_int - start_int + 1

    used_leases = 0
    lease_path = find_path(ctx, LEASE_PATHS)
    if lease_path != None:
        for lip in parse_leases(ctx.file_read(lease_path)):
            lint = ip_to_int(lip)
            if (start_int <= lint) and (lint <= end_int):
                used_leases += 1

    free_leases = total_leases - used_leases
    free_pct = 0.0
    if total_leases > 0:
        free_pct = 100.0 * free_leases / total_leases

    free_levels = params.get("free_leases", [15.0, 5.0])
    warn_pct = free_levels[0]
    crit_pct = free_levels[1]

    pool_state = "CRIT" if free_pct < crit_pct else ("WARN" if free_pct < warn_pct else "OK")

    final_state = pool_state
    if STATE_RANK.get(daemon_state, 0) > STATE_RANK.get(pool_state, 0):
        final_state = daemon_state

    msg_parts = []
    if daemon_msg:
        msg_parts.append(daemon_msg)
    msg_parts.append(
        "Free: %d/%d (%f%%), Used: %d" % (free_leases, total_leases, free_pct, used_leases)
    )

    return {
        "changed": False,
        "msg": "; ".join(msg_parts),
        "data": {
            "state": final_state,
            "metrics": {
                "free_leases": free_leases,
                "used_leases": used_leases,
                "total_leases": total_leases,
            },
            "details": "",
        },
    }