# yoloman.network_interface — read + configure host network interfaces.
#
# Baked into the agent (go:embed). state=gathered reads the current config by
# parsing `ip` output + /etc/resolv.conf (text-parsing, no external json);
# state=present/absent configures via NetworkManager (nmcli), which is the one
# provider we can drive uniformly. Mutating steps are mutates=True so the
# runtime enforces check_mode + the write gate. Contract shape: {changed, msg,
# data}.

def main(ctx, params):
    state = params.get("state", "gathered")
    if state == "gathered":
        return _gather(ctx)
    if state not in ("present", "absent"):
        fail("state must be one of: gathered, present, absent")
    name = params.get("name")
    if not name:
        fail("name (the interface / connection) is required for state=%s" % state)
    return _configure(ctx, params, name, state)


# ---- read (gathered) ------------------------------------------------------

def _gather(ctx):
    return {
        "changed": False,
        "msg": "gathered network configuration",
        "data": {
            "interfaces": _gather_interfaces(ctx),
            "routes": _gather_routes(ctx),
            "dns": _gather_dns(ctx),
        },
    }


def _gather_interfaces(ctx):
    # Link state first: "2: eth0: <..,UP,..> mtu 1500 ... state UP ..."
    ifaces = {}
    order = []
    link = ctx.run(["ip", "-o", "link", "show"], mutates=False)
    for line in link.stdout.split("\n"):
        if not line.strip():
            continue
        toks = line.split()
        if len(toks) < 2:
            continue
        ifname = toks[1].rstrip(":")
        # drop an "@parent" suffix (e.g. vlan @eth0)
        ifname = ifname.split("@")[0]
        st = "unknown"
        for i in range(len(toks) - 1):
            if toks[i] == "state":
                st = toks[i + 1]
                break
        if ifname not in ifaces:
            ifaces[ifname] = {"name": ifname, "state": st, "addresses": []}
            order.append(ifname)

    # Addresses: "2: eth0    inet 10.0.0.5/24 brd ... scope global eth0"
    addr = ctx.run(["ip", "-o", "addr", "show"], mutates=False)
    for line in addr.stdout.split("\n"):
        if not line.strip():
            continue
        toks = line.split()
        if len(toks) < 4:
            continue
        ifname = toks[1].rstrip(":").split("@")[0]
        family = ""
        cidr = ""
        for i in range(len(toks) - 1):
            if toks[i] == "inet" or toks[i] == "inet6":
                family = toks[i]
                cidr = toks[i + 1]
                break
        if not family:
            continue
        if ifname not in ifaces:
            ifaces[ifname] = {"name": ifname, "state": "unknown", "addresses": []}
            order.append(ifname)
        ifaces[ifname]["addresses"].append({"family": family, "cidr": cidr})

    return [ifaces[n] for n in order]


def _gather_routes(ctx):
    res = ctx.run(["ip", "route", "show"], mutates=False)
    routes = []
    for line in res.stdout.split("\n"):
        line = line.strip()
        if not line:
            continue
        toks = line.split()
        entry = {"raw": line, "dest": toks[0]}
        for i in range(len(toks) - 1):
            if toks[i] == "via":
                entry["gateway"] = toks[i + 1]
            elif toks[i] == "dev":
                entry["dev"] = toks[i + 1]
        routes.append(entry)
    return routes


def _gather_dns(ctx):
    nameservers = []
    search = []
    if ctx.file_exists("/etc/resolv.conf"):
        content = ctx.file_read("/etc/resolv.conf")
        for line in content.split("\n"):
            line = line.strip()
            if line.startswith("nameserver"):
                parts = line.split()
                if len(parts) >= 2:
                    nameservers.append(parts[1])
            elif line.startswith("search") or line.startswith("domain"):
                search.extend(line.split()[1:])
    return {"nameservers": nameservers, "search": search}


# ---- configure (present / absent) via NetworkManager ----------------------

def _configure(ctx, params, name, state):
    probe = ctx.run(["sh", "-c", "command -v nmcli"], mutates=False)
    if probe.rc != 0:
        fail("network configuration requires NetworkManager (nmcli not found on this host)")

    if state == "absent":
        res = ctx.run(["nmcli", "connection", "delete", name], mutates=True)
        if res.rc == 0:
            return {"changed": True, "msg": "deleted connection %s" % name, "data": {"name": name}}
        # nmcli returns 10 when the connection doesn't exist -> idempotent
        if "unknown connection" in res.stderr or res.rc == 10:
            return {"changed": False, "msg": "connection %s already absent" % name, "data": {"name": name}}
        fail("failed to delete connection %s: %s" % (name, res.stderr))

    method = params.get("method", "dhcp")
    if method not in ("dhcp", "static", "manual"):
        fail("method must be one of: dhcp, static, manual")

    # Does a connection with this name already exist?
    existing = ctx.run(["nmcli", "-t", "-f", "NAME", "connection", "show"], mutates=False)
    have = False
    for line in existing.stdout.split("\n"):
        if line.strip() == name:
            have = True
            break

    if have:
        cmd = ["nmcli", "connection", "modify", name]
    else:
        cmd = ["nmcli", "connection", "add", "type", "ethernet", "con-name", name, "ifname", name]

    if method == "dhcp":
        cmd.extend(["ipv4.method", "auto"])
    else:
        address = params.get("address")
        if not address:
            fail("address (CIDR, e.g. 10.0.0.5/24) is required for method=%s" % method)
        cmd.extend(["ipv4.method", "manual", "ipv4.addresses", address])
        gateway = params.get("gateway")
        if gateway:
            cmd.extend(["ipv4.gateway", gateway])
        dns = params.get("dns", [])
        if dns:
            cmd.extend(["ipv4.dns", ",".join(dns)])

    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("nmcli failed to configure %s: %s" % (name, res.stderr))
    # Apply the connection (no-op / skipped in check_mode).
    ctx.run(["nmcli", "connection", "up", name], mutates=True)
    return {
        "changed": True,
        "msg": "%s connection %s (%s)" % ("modified" if have else "added", name, method),
        "data": {"name": name, "method": method, "existed": have},
    }
