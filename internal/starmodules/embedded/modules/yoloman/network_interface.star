# yoloman.network_interface — read + configure host network interfaces,
# independent of the underlying network provider.
#
# state=gathered reads the current config by parsing `ip` output +
# /etc/resolv.conf (text-parsing, no external json) and reports which provider
# manages the host (networkmanager / netplan / networkd / ifupdown).
#
# state=present/absent configures the interface via whichever provider is
# active on the host — Cockpit leans on NetworkManager only; we detect and
# drive NetworkManager (nmcli), netplan (Ubuntu), systemd-networkd, or the
# classic Debian ifupdown /etc/network/interfaces.d, so the same UI works on
# every host regardless of its network stack. A caller may force one with the
# `provider` param. Mutating steps are mutates=True / file_write so the runtime
# enforces check_mode + the write gate. Contract shape: {changed, msg, data}.

def main(ctx, params):
    state = params.get("state", "gathered")
    if state == "gathered":
        return _gather(ctx)
    if state not in ("present", "absent"):
        fail("state must be one of: gathered, present, absent")
    name = params.get("name")
    if not name:
        fail("name (the interface / connection) is required for state=%s" % state)
    provider = params.get("provider") or _detect_provider(ctx)
    return _configure(ctx, params, name, state, provider)


# ---- read (gathered) ------------------------------------------------------

def _gather(ctx):
    return {
        "changed": False,
        "msg": "gathered network configuration",
        "data": {
            "provider": _detect_provider(ctx),
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
        mtu = 0
        mac = ""
        for i in range(len(toks) - 1):
            if toks[i] == "state":
                st = toks[i + 1]
            elif toks[i] == "mtu":
                mtu = int(toks[i + 1]) if toks[i + 1].isdigit() else 0
            elif toks[i] == "link/ether":
                mac = toks[i + 1]
        if ifname not in ifaces:
            ifaces[ifname] = {"name": ifname, "state": st, "mtu": mtu, "mac": mac, "addresses": []}
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
            ifaces[ifname] = {"name": ifname, "state": "unknown", "mtu": 0, "mac": "", "addresses": []}
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


# ---- provider detection ---------------------------------------------------

def _cmd_exists(ctx, cmd):
    return ctx.run(["sh", "-c", "command -v %s" % cmd], mutates=False).rc == 0


def _service_active(ctx, unit):
    res = ctx.run(["systemctl", "is-active", unit], mutates=False)
    return res.rc == 0 and res.stdout.strip() == "active"


# _detect_provider picks the config system that actually manages this host's
# interfaces, in order of how authoritative each is when present.
def _detect_provider(ctx):
    # NetworkManager: only if it is the running manager (nmcli present alone is
    # not enough — some hosts ship nmcli but run networkd/ifupdown).
    if _cmd_exists(ctx, "nmcli"):
        st = ctx.run(["nmcli", "-t", "-f", "RUNNING", "general"], mutates=False)
        if st.rc == 0 and "running" in st.stdout.lower():
            return "networkmanager"
    # netplan (Ubuntu Server) — the renderer binary implies netplan owns config.
    if _cmd_exists(ctx, "netplan"):
        return "netplan"
    # systemd-networkd
    if _cmd_exists(ctx, "networkctl") and _service_active(ctx, "systemd-networkd"):
        return "networkd"
    # classic Debian ifupdown
    if ctx.file_exists("/etc/network/interfaces"):
        return "ifupdown"
    # last resort: a present-but-not-yet-running NetworkManager
    if _cmd_exists(ctx, "nmcli"):
        return "networkmanager"
    return "unknown"


# ---- configure (present / absent) -----------------------------------------

def _configure(ctx, params, name, state, provider):
    if provider == "networkmanager":
        return _configure_nm(ctx, params, name, state)
    if provider == "netplan":
        return _configure_netplan(ctx, params, name, state)
    if provider == "networkd":
        return _configure_networkd(ctx, params, name, state)
    if provider == "ifupdown":
        return _configure_ifupdown(ctx, params, name, state)
    fail("no supported network provider detected on this host (looked for NetworkManager, netplan, systemd-networkd, ifupdown)")


# read + validate the common present-mode params (method/address/gateway/dns
# + optional mtu/mac which apply to any method).
def _present_params(params):
    method = params.get("method", "dhcp")
    if method not in ("dhcp", "static", "manual"):
        fail("method must be one of: dhcp, static, manual")
    address = params.get("address")
    gateway = params.get("gateway")
    dns = params.get("dns", []) or []
    if method != "dhcp" and not address:
        fail("address (CIDR, e.g. 10.0.0.5/24) is required for method=%s" % method)
    mtu = params.get("mtu", 0) or 0
    mac = params.get("mac", "") or ""
    return method, address, gateway, dns, mtu, mac


# --- NetworkManager (nmcli) ---

def _configure_nm(ctx, params, name, state):
    if state == "absent":
        res = ctx.run(["nmcli", "connection", "delete", name], mutates=True)
        if res.rc == 0:
            return {"changed": True, "msg": "deleted connection %s" % name, "data": {"name": name, "provider": "networkmanager"}}
        if "unknown connection" in res.stderr or res.rc == 10:
            return {"changed": False, "msg": "connection %s already absent" % name, "data": {"name": name, "provider": "networkmanager"}}
        fail("failed to delete connection %s: %s" % (name, res.stderr))

    method, address, gateway, dns, mtu, mac = _present_params(params)

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
        cmd.extend(["ipv4.method", "manual", "ipv4.addresses", address])
        if gateway:
            cmd.extend(["ipv4.gateway", gateway])
        if dns:
            cmd.extend(["ipv4.dns", ",".join(dns)])
    if mtu:
        cmd.extend(["802-3-ethernet.mtu", str(mtu)])
    if mac:
        cmd.extend(["802-3-ethernet.cloned-mac-address", mac])

    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("nmcli failed to configure %s: %s" % (name, res.stderr))
    ctx.run(["nmcli", "connection", "up", name], mutates=True)
    return {
        "changed": True,
        "msg": "%s connection %s (%s) via NetworkManager" % ("modified" if have else "added", name, method),
        "data": {"name": name, "method": method, "existed": have, "provider": "networkmanager"},
    }


# --- netplan (Ubuntu) ---

def _netplan_path(name):
    return "/etc/netplan/90-yoloman-%s.yaml" % name


def _configure_netplan(ctx, params, name, state):
    path = _netplan_path(name)
    if state == "absent":
        if not ctx.file_exists(path):
            return {"changed": False, "msg": "netplan config for %s already absent" % name, "data": {"name": name, "provider": "netplan"}}
        # empty the managed file, then apply
        changed = ctx.file_write(path, "network:\n  version: 2\n", mode="0600")
        _netplan_apply(ctx)
        return {"changed": changed, "msg": "removed netplan config for %s" % name, "data": {"name": name, "path": path, "provider": "netplan"}}

    method, address, gateway, dns, mtu, mac = _present_params(params)
    lines = ["network:", "  version: 2", "  ethernets:", "    %s:" % name]
    if method == "dhcp":
        lines.append("      dhcp4: true")
    else:
        lines.append("      dhcp4: false")
        lines.append("      addresses: [%s]" % address)
        if gateway:
            # routes: is the modern replacement for the deprecated gateway4
            lines.append("      routes:")
            lines.append("        - to: default")
            lines.append("          via: %s" % gateway)
        if dns:
            lines.append("      nameservers:")
            lines.append("        addresses: [%s]" % ", ".join(dns))
    if mtu:
        lines.append("      mtu: %d" % mtu)
    if mac:
        lines.append("      macaddress: %s" % mac)
    content = "\n".join(lines) + "\n"
    changed = ctx.file_write(path, content, mode="0600")
    _netplan_apply(ctx)
    return {
        "changed": changed,
        "msg": "wrote netplan config for %s (%s)" % (name, method),
        "data": {"name": name, "method": method, "path": path, "provider": "netplan"},
    }


def _netplan_apply(ctx):
    ctx.run(["netplan", "apply"], mutates=True)


# --- systemd-networkd ---

def _networkd_path(name):
    return "/etc/systemd/network/90-yoloman-%s.network" % name


def _configure_networkd(ctx, params, name, state):
    path = _networkd_path(name)
    if state == "absent":
        if not ctx.file_exists(path):
            return {"changed": False, "msg": "networkd config for %s already absent" % name, "data": {"name": name, "provider": "networkd"}}
        # write an inert Match-only unit, then reload
        changed = ctx.file_write(path, "[Match]\nName=%s\n" % name, mode="0644")
        ctx.run(["networkctl", "reload"], mutates=True)
        return {"changed": changed, "msg": "removed networkd config for %s" % name, "data": {"name": name, "path": path, "provider": "networkd"}}

    method, address, gateway, dns, mtu, mac = _present_params(params)
    lines = ["[Match]", "Name=%s" % name, ""]
    if mtu or mac:
        lines.append("[Link]")
        if mtu:
            lines.append("MTUBytes=%d" % mtu)
        if mac:
            lines.append("MACAddress=%s" % mac)
        lines.append("")
    lines.append("[Network]")
    if method == "dhcp":
        lines.append("DHCP=ipv4")
    else:
        lines.append("Address=%s" % address)
        if gateway:
            lines.append("Gateway=%s" % gateway)
        for server in dns:
            lines.append("DNS=%s" % server)
    content = "\n".join(lines) + "\n"
    changed = ctx.file_write(path, content, mode="0644")
    ctx.run(["networkctl", "reload"], mutates=True)
    ctx.run(["networkctl", "reconfigure", name], mutates=True)
    return {
        "changed": changed,
        "msg": "wrote systemd-networkd config for %s (%s)" % (name, method),
        "data": {"name": name, "method": method, "path": path, "provider": "networkd"},
    }


# --- ifupdown (Debian /etc/network/interfaces.d) ---

def _ifupdown_path(name):
    return "/etc/network/interfaces.d/yoloman-%s" % name


def _configure_ifupdown(ctx, params, name, state):
    path = _ifupdown_path(name)
    if state == "absent":
        if not ctx.file_exists(path):
            return {"changed": False, "msg": "ifupdown config for %s already absent" % name, "data": {"name": name, "provider": "ifupdown"}}
        ctx.run(["ifdown", name], mutates=True)
        # blank the managed stanza file
        changed = ctx.file_write(path, "", mode="0644")
        return {"changed": changed, "msg": "removed ifupdown config for %s" % name, "data": {"name": name, "path": path, "provider": "ifupdown"}}

    method, address, gateway, dns, mtu, mac = _present_params(params)
    lines = ["auto %s" % name]
    if method == "dhcp":
        lines.append("iface %s inet dhcp" % name)
    else:
        lines.append("iface %s inet static" % name)
        # modern ifupdown accepts CIDR directly in `address`
        lines.append("    address %s" % address)
        if gateway:
            lines.append("    gateway %s" % gateway)
        if dns:
            lines.append("    dns-nameservers %s" % " ".join(dns))
    if mtu:
        lines.append("    mtu %d" % mtu)
    if mac:
        lines.append("    hwaddress ether %s" % mac)
    content = "\n".join(lines) + "\n"
    changed = ctx.file_write(path, content, mode="0644")
    # apply: bring it down (ignore failure if never up) then up
    ctx.run(["ifdown", name], mutates=True, ok_codes=[0, 1])
    ctx.run(["ifup", name], mutates=True)
    return {
        "changed": changed,
        "msg": "wrote ifupdown config for %s (%s)" % (name, method),
        "data": {"name": name, "method": method, "path": path, "provider": "ifupdown"},
    }
