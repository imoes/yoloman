def main(ctx, params):
    conn_name = params["conn_name"]
    state = params["state"]
    conn_type = params.get("type")
    ifname = params.get("ifname")
    autoconnect = params.get("autoconnect", True)
    if autoconnect == None:
        autoconnect = True
    if ifname == None:
        ifname = conn_name

    # State validation
    if state not in ("present", "absent"):
        fail("unsupported state: " + state)

    # Check existing connection
    res = ctx.run(["nmcli", "-t", "-f", "name,device,type", "connection", "show", "--active", "--order", "name"])
    active_connections = res.stdout.strip().split("\n")[1:] if res.rc == 0 and res.stdout.strip() else []
    existing = {}
    for line in active_connections:
        if not line.strip():
            continue
        parts = line.split(":")
        if len(parts) >= 1:
            name = parts[0]
            if name == conn_name:
                existing["active"] = True
                existing["device"] = parts[1] if len(parts) > 1 else ""
                existing["type"] = parts[2] if len(parts) > 2 else ""
                break

    # Check for existing connection (inactive too)
    res = ctx.run(["nmcli", "-t", "-f", "name,device,type", "connection", "show"])
    all_connections = res.stdout.strip().split("\n")[1:] if res.rc == 0 and res.stdout.strip() else []
    for line in all_connections:
        if not line.strip():
            continue
        parts = line.split(":")
        if len(parts) >= 1 and parts[0] == conn_name:
            existing["exists"] = True
            break

    # Handle absent state
    if state == "absent":
        if not existing:
            return {"changed": False, "msg": "connection " + conn_name + " does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete " + conn_name}
        res = ctx.run(["nmcli", "connection", "delete", conn_name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete " + conn_name}
        if res.rc != 0:
            fail("failed to delete connection " + conn_name + ": " + res.stderr)
        return {"changed": True, "msg": "deleted " + conn_name}

    # Handle present state
    # Build nmcli connection add command
    args = ["nmcli", "connection", "add", "type", conn_type or "ethernet", "con-name", conn_name]
    if conn_type:
        args.extend(["type", conn_type])
    args.extend(["ifname", ifname])

    # Autoconnect
    args.extend(["autoconnect", "yes" if autoconnect else "no"])

    # Basic options
    if params.get("master"):
        args.extend(["master", params["master"]])
    if params.get("mode"):
        args.extend(["mode", params["mode"]])
    if params.get("miimon"):
        args.extend(["miimon", str(params["miimon"])])
    if params.get("dns4"):
        args.extend(["ipv4.dns", ",".join(params["dns4"])])
    if params.get("dns4_search"):
        args.extend(["ipv4.dns-search", ";".join(params["dns4_search"])])
    if params.get("dns6"):
        args.extend(["ipv6.dns", ",".join(params["dns6"])])
    if params.get("dns6_search"):
        args.extend(["ipv6.dns-search", ";".join(params["dns6_search"])])
    if params.get("ip4"):
        args.extend(["ipv4.addresses", ",".join(params["ip4"])])
    if params.get("gw4"):
        args.extend(["ipv4.gateway", params["gw4"]])
    if params.get("method4"):
        args.extend(["ipv4.method", params["method4"]])
    if params.get("ip6"):
        args.extend(["ipv6.addresses", ",".join(params["ip6"])])
    if params.get("gw6"):
        args.extend(["ipv6.gateway", params["gw6"]])
    if params.get("method6"):
        args.extend(["ipv6.method", params["method6"]])
    if params.get("mtu"):
        args.extend(["mtu", str(params["mtu"])])
    if params.get("mac"):
        args.extend(["mac", params["mac"]])
    if params.get("zone"):
        args.extend(["connection.zone", params["zone"]])

    # Bridge options
    if params.get("bridge") or (conn_type == "bridge"):
        if params.get("forwarddelay"):
            args.extend(["bridge.forward-delay", str(params["forwarddelay"])])
        if params.get("ageingtime"):
            args.extend(["bridge.ageing-time", str(params["ageingtime"])])
        if params.get("priority"):
            args.extend(["bridge.priority", str(params["priority"])])
        if params.get("stopping") == None:
            args.extend(["bridge.stp", "yes" if params.get("stp", True) else "no"])
        else:
            args.extend(["bridge.stp", "yes" if params.get("stopping") else "no"])
    if conn_type == "bridge-slave":
        if params.get("slavepriority"):
            args.extend(["bridge-port.priority", str(params["slavepriority"])])
        if params.get("path_cost"):
            args.extend(["bridge-port.path-cost", str(params["path_cost"])])
        if params.get("hairpin"):
            args.extend(["bridge-port.hairpin", "yes" if params["hairpin"] else "no"])

    # Bond options
    if conn_type == "bond":
        if params.get("mode"):
            args.extend(["bond.mode", params["mode"]])
        if params.get("miimon"):
            args.extend(["bond.miimon", str(params["miimon"])])
        if params.get("primary"):
            args.extend(["bond.primary", params["primary"]])
        if params.get("downdelay"):
            args.extend(["bond.downdelay", str(params["downdelay"])])
        if params.get("updelay"):
            args.extend(["bond.updelay", str(params["updelay"])])
        if params.get("arp_interval"):
            args.extend(["bond.arp-interval", str(params["arp_interval"])])
        if params.get("arp_ip_target"):
            args.extend(["bond.arp-ip-target", params["arp_ip_target"]])
        if params.get("xmit_hash_policy"):
            args.extend(["bond.xmit_hash_policy", params["xmit_hash_policy"]])
    if conn_type == "bond-slave":
        if params.get("master"):
            args.extend(["master", params["master"]])

    # VLAN options
    if conn_type == "vlan":
        if params.get("vlanid") == None:
            fail("vlanid is required for vlan connections")
        args.extend(["vlan.id", str(params["vlanid"])])
        if params.get("vlandev"):
            args.extend(["vlan.parent", params["vlandev"]])
        if params.get("flags"):
            args.extend(["vlan.flags", params["flags"]])
        if params.get("ingress"):
            args.extend(["vlan.ingress-priority-map", params["ingress"]])
        if params.get("egress"):
            args.extend(["vlan.egress-priority-map", params["egress"]])

    # Team options
    if conn_type == "team":
        runner = params.get("runner", "roundrobin")
        args.extend(["team.runner", runner])
        if runner == "lacp":
            if params.get("runner_hwaddr_policy"):
                args.extend(["team.runner_hwaddr_policy", params["runner_hwaddr_policy"]])
            if params.get("runner_fast_rate"):
                args.extend(["team.runner_fast_rate", "yes" if params["runner_fast_rate"] else "no"])

    # Infiniband options
    if conn_type == "infiniband":
        if params.get("transport_mode"):
            args.extend(["infiniband.transport_mode", params["transport_mode"]])
        if params.get("p_key"):
            args.extend(["infiniband.p_key", str(params["p_key"])])
        if params.get("base_hwaddr"):
            args.extend(["infiniband.base_hwaddr", params["base_hwaddr"]])

    # Wifi options
    if conn_type == "wifi":
        if params.get("ssid"):
            args.extend(["wifi.ssid", params["ssid"]])
        if params.get("wifi"):
            wifi_opts = params["wifi"]
            if wifi_opts.get("mode"):
                args.extend(["wifi.mode", wifi_opts["mode"]])
            if wifi_opts.get("bssid"):
                args.extend(["wifi.bssid", wifi_opts["bssid"]])
            if wifi_opts.get("hidden"):
                args.extend(["wifi.hidden", "yes" if wifi_opts["hidden"] else "no"])
            if wifi_opts.get("band"):
                args.extend(["wifi.band", wifi_opts["band"]])
            if wifi_opts.get("channel"):
                args.extend(["wifi.channel", str(wifi_opts["channel"])])

    # Wifi security options
    if conn_type == "wifi" and params.get("wifi_sec"):
        wifi_sec = params["wifi_sec"]
        if wifi_sec.get("key-mgmt"):
            args.extend(["wifi-sec.key-mgmt", wifi_sec["key-mgmt"]])
        if wifi_sec.get("psk"):
            args.extend(["wifi-sec.psk", wifi_sec["psk"]])
        if wifi_sec.get("auth-alg"):
            args.extend(["wifi-sec.auth-alg", wifi_sec["auth-alg"]])
        if wifi_sec.get("psk-flags"):
            args.extend(["wifi-sec.psk-flags", str(wifi_sec["psk-flags"])])

    # GSM options
    if conn_type == "gsm" and params.get("gsm"):
        gsm = params["gsm"]
        if gsm.get("apn"):
            args.extend(["gsm.apn", gsm["apn"]])
        if gsm.get("pin"):
            args.extend(["gsm.pin", gsm["pin"]])
        if gsm.get("username"):
            args.extend(["gsm.username", gsm["username"]])
        if gsm.get("password"):
            args.extend(["gsm.password", gsm["password"]])

    # Execute connection creation
    if not existing.get("exists"):
        if ctx.check_mode:
            return {"changed": True, "msg": "would create " + conn_name}
        res = ctx.run(args, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create " + conn_name}
        if res.rc != 0:
            fail("failed to create connection " + conn_name + ": " + res.stderr)
        return {"changed": True, "msg": "created " + conn_name}

    # Connection already exists - check if modification is needed
    # (This is a simplified check - real implementation would compare all settings)
    return {"changed": False, "msg": conn_name + " already exists"}
