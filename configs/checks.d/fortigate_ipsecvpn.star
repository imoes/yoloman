def _snmp_get_value(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 0:
        return res.stdout.strip()
    if res.rc == 127:
        fail("snmpget not installed")
    return None


def _is_fortigate(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sysoid = ".1.3.6.1.2.1.1.2.0"
    val = _snmp_get_value(ctx, host, community, sysoid)
    if val == None:
        return False
    prefix = ".1.3.6.1.4.1.12356.101.1."
    if val.startswith(prefix):
        return True
    return False


def main(ctx, params):
    if params.get("_discover"):
        if not _is_fortigate(ctx, params):
            return {
                "changed": False,
                "msg": "no FortiGate device found",
                "data": {"discovery": []},
            }

        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.12356.101.12.2.2.1"

        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid + ".3"],
            mutates=False,
        )
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "no FortiGate IPSec VPN tunnels found",
                "data": {"discovery": []},
            }

        rows = []
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[0:sp]
            val = line[sp + 1:]
            idx = oid[len(base_oid + ".3") + 1:]
            if idx:
                rows.append(idx)

        if len(rows) == 0:
            return {
                "changed": False,
                "msg": "no FortiGate IPSec VPN tunnels found",
                "data": {"discovery": []},
            }

        metrics = ["active_vpn_tunnels"]
        discovery = []
        for idx in rows:
            discovery.append({
                "item": idx,
                "params": {
                    "tunnels_ignore_levels": [],
                    "levels": [1, 2],
                },
                "metrics": metrics,
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    if not _is_fortigate(ctx, params):
        return {
            "changed": False,
            "msg": "no FortiGate device found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "FortiGate device not reachable or not a FortiGate",
            },
        }

    base_oid = ".1.3.6.1.4.1.12356.101.12.2.2.1"
    col_name = "3"
    col_status = "20"

    name_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid + "." + col_name],
        mutates=False,
    )
    status_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid + "." + col_status],
        mutates=False,
    )

    if name_res.rc != 0 or status_res.rc != 0:
        return {
            "changed": False,
            "msg": "no FortiGate IPSec VPN data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Failed to retrieve IPSec VPN tunnel data",
            },
        }

    name_map = {}
    for line in name_res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[0:sp]
        val = line[sp + 1:].strip().strip('"')
        idx = oid[len(base_oid + "." + col_name) + 1:]
        if idx:
            name_map[idx] = val

    status_map = {}
    for line in status_res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[0:sp]
        val = line[sp + 1:]
        idx = oid[len(base_oid + "." + col_status) + 1:]
        if idx:
            status_map[idx] = val

    section = []
    for idx in sorted(name_map.keys()):
        p2name = name_map[idx]
        if item and item != idx:
            continue
        ent_status = status_map.get(idx, "")
        section.append((p2name, ent_status))

    if len(section) == 0 and item:
        return {
            "changed": False,
            "msg": "no such tunnel: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Tunnel item not found",
            },
        }

    tunnels_ignore_levels = params.get("tunnels_ignore_levels", [])
    tunnels_down = []
    tunnels_ignored = []
    for p2name, ent_status in section:
        if ent_status == "1":
            tunnels_down.append(p2name)
            if p2name in tunnels_ignore_levels:
                tunnels_ignored.append(p2name)

    num_total = len(section)
    num_down = len(tunnels_down)
    num_up = num_total - num_down
    num_ignored = len(tunnels_ignored)
    num_down_and_not_ignored = num_down - num_ignored

    infotext = "Total: %d, Up: %d, Down: %d, Ignored: %d" % (
        num_total, num_up, num_down, num_ignored
    )

    levels = params.get("levels", (1, 2))
    warn = levels[0]
    crit = levels[1]
    state = "OK"
    if crit != None and num_down_and_not_ignored >= crit:
        state = "CRIT"
    elif warn != None and num_down_and_not_ignored >= warn:
        state = "WARN"
    if state != "OK":
        infotext += " (warn/crit at %s/%s)" % (warn, crit)

    details = infotext + "\n"
    long_output = []
    for title, tunnels in [
        ("Down and not ignored", sorted(set(tunnels_down) - set(tunnels_ignored))),
        ("Down", sorted(set(tunnels_down))),
        ("Ignored", sorted(set(tunnels_ignored))),
    ]:
        if tunnels:
            long_output.append(title + ":")
            long_output.append(", ".join(tunnels))
    if long_output:
        details += "\n".join(long_output)

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": {"active_vpn_tunnels": num_up},
            "details": details,
        },
    }