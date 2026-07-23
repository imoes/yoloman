def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/dhcp/dhcpd.leases"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read leases file",
                    "data": {"discovery": []}}

        # Parse dhcpd.leases file to extract pools and leases
        pools = {}
        leases = []
        lines = res.stdout.splitlines()
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("pool "):
                # Extract pool range
                start = None
                end = None
                i += 1
                while i < len(lines):
                    inner = lines[i].strip()
                    if inner == "}":
                        break
                    if inner.startswith("range "):
                        parts = inner.split()
                        if len(parts) >= 3:
                            start = parts[1]
                            end = parts[2].rstrip(";")
                        break
                    i += 1
                if start and end:
                    item = start + "-" + end
                    pools[item] = {"start": start, "end": end}
            elif line.startswith("lease "):
                parts = line.split()
                if len(parts) >= 2:
                    addr = parts[1].rstrip(";")
                    leases.append(addr)
            i += 1

        # Build discovery result
        out = []
        for item in pools:
            out.append({"item": item, "params": {"free_leases": (15.0, 5.0)},
                        "metrics": ["free_leases", "used_leases"]})
        return {"changed": False, "msg": "discovered %d DHCP pools" % len(out),
                "data": {"discovery": out}}

    # ===== CHECK MODE =====
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/dhcp/dhcpd.leases"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read leases file",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse dhcpd.leases to find requested pool
    pools = {}
    leases = []
    lines = res.stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("pool "):
            start = None
            end = None
            i += 1
            while i < len(lines):
                inner = lines[i].strip()
                if inner == "}":
                    break
                if inner.startswith("range "):
                    parts = inner.split()
                    if len(parts) >= 3:
                        start = parts[1]
                        end = parts[2].rstrip(";")
                    break
                i += 1
            if start and end:
                item_key = start + "-" + end
                pools[item_key] = {"start": start, "end": end}
        elif line.startswith("lease "):
            parts = line.split()
            if len(parts) >= 2:
                addr = parts[1].rstrip(";")
                leases.append(addr)
        i += 1

    # Check for daemon status (check for running dhcpd process)
    daemon_res = ctx.run(["pgrep", "-x", "dhcpd"], mutates=False)
    pids = daemon_res.stdout.strip().splitlines() if daemon_res.stdout.strip() else []
    pids = [int(pid) for pid in pids if pid.isdigit()]

    # Validate daemon status
    if len(pids) == 0:
        return {"changed": False, "msg": "DHCP Daemon not running",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    elif len(pids) > 1:
        return {"changed": False, "msg": "DHCP Daemon running %d times (PIDs: %s)" %
                (len(pids), ", ".join([str(p) for p in pids])),
                "data": {"state": "WARN", "metrics": {}, "details": ""}}

    # Check requested pool
    pool = pools.get(item)
    if not pool:
        return {"changed": False, "msg": "pool not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Convert dotted IP to integer
    def ip_to_int(ip):
        octets = ip.split(".")
        if len(octets) != 4:
            return -1
        for octet in octets:
            if not octet.isdigit():
                return -1
        return (int(octets[0]) << 24) + (int(octets[1]) << 16) + (int(octets[2]) << 8) + int(octets[3])

    start_int = ip_to_int(pool["start"])
    end_int = ip_to_int(pool["end"])

    if start_int < 0 or end_int < 0:
        return {"changed": False, "msg": "invalid IP range",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    num_leases = end_int - start_int + 1
    used_count = 0
    for lease in leases:
        lease_int = ip_to_int(lease)
        if lease_int >= 0 and (start_int <= lease_int) and (lease_int <= end_int):
            used_count += 1

    # Calculate free leases
    free_leases = num_leases - used_count

    # Apply thresholds
    warn_level, crit_level = params.get("free_leases", (15.0, 5.0))

    # Check thresholds
    state = "OK"
    if free_leases <= crit_level:
        state = "CRIT"
    elif free_leases <= warn_level:
        state = "WARN"

    return {"changed": False,
            "msg": "free leases: %d, used leases: %d" % (free_leases, used_count),
            "data": {"state": state,
                     "metrics": {"free_leases": free_leases, "used_leases": used_count},
                     "details": ""}}