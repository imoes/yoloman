def main(ctx, params):
    # Extract and validate required params
    state = params.get("state")
    if state not in ["absent", "disabled", "enabled", "present"]:
        fail("state must be one of: absent, disabled, enabled, present")

    zone = params.get("zone")
    permanent = params.get("permanent")
    immediate = params.get("immediate", False)
    timeout = params.get("timeout", 0)

    # Default: if neither permanent nor immediate is set, assume immediate
    if permanent == None and not immediate:
        immediate = True

    # Sanity: zone operations require permanent
    if zone != None and permanent == False:
        fail("zone operations must be permanent. Make sure 'permanent' is not set to false or 'immediate' to true")

    # Check if firewall is online for immediate operations
    if immediate:
        res = ctx.run(["systemctl", "is-active", "firewalld"])
        if res.rc != 0:
            fail("firewalld is not running; cannot perform immediate actions")

    # Determine modification type
    services = params.get("service")
    protocols = params.get("protocol")
    ports = params.get("port")
    port_forward = params.get("port_forward")
    rich_rule = params.get("rich_rule")
    interface = params.get("interface")
    masquerade = params.get("masquerade")
    source = params.get("source")
    icmp_block = params.get("icmp_block")
    icmp_block_inversion = params.get("icmp_block_inversion")
    target = params.get("target")

    modification_count = sum([
        services != None,
        protocols != None,
        ports != None,
        port_forward != None,
        rich_rule != None,
        interface != None,
        masquerade != None,
        source != None,
        icmp_block != None,
        icmp_block_inversion != None,
        target != None,
    ])
    
    if modification_count > 0 and state in ["absent", "present"] and target == None:
        fail("absent and present state can only be used in zone level operations (no other parameters)")

    # Zone transaction (create/delete zone only)
    if modification_count == 0 and zone != None:
        if state == "present":
            res = ctx.run(["firewall-cmd", "--permanent", "--query-zone", zone])
            if res.rc == 0:
                return {"changed": False, "msg": "zone " + zone + " already exists"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would create zone " + zone}
            res = ctx.run(["firewall-cmd", "--permanent", "--new-zone=" + zone])
            if res.rc != 0:
                fail("failed to create zone " + zone + ": " + res.stderr)
            return {"changed": True, "msg": "added zone " + zone}
        elif state == "absent":
            res = ctx.run(["firewall-cmd", "--permanent", "--query-zone", zone])
            if res.rc != 0:
                return {"changed": False, "msg": "zone " + zone + " does not exist"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete zone " + zone}
            res = ctx.run(["firewall-cmd", "--permanent", "--delete-zone=" + zone])
            if res.rc != 0:
                fail("failed to delete zone " + zone + ": " + res.stderr)
            return {"changed": True, "msg": "removed zone " + zone}
        fail("unsupported state for zone-only operation: " + state)

    if zone == None:
        fail("zone parameter is required for all non-zone operations")

    # Helper for permanent/active state queries
    def _query_service(zone, service):
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--query-service=" + service])
        return res.rc == 0

    def _query_protocol(zone, protocol):
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--query-protocol=" + protocol])
        return res.rc == 0

    def _query_port(zone, port, protocol):
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--query-port=" + port + "/" + protocol])
        return res.rc == 0

    def _query_rich_rule(zone, rule):
        # Normalize rule string for comparison
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--query-rich-rule", rule])
        return res.rc == 0

    def _query_interface(zone, iface):
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--query-interface=" + iface])
        return res.rc == 0

    def _query_masquerade(zone):
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--query-masquerade"])
        return res.rc == 0

    def _query_source(zone, source_ip):
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--query-source=" + source_ip])
        return res.rc == 0

    def _query_icmp_block(zone, icmp):
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--query-icmp-block=" + icmp])
        return res.rc == 0

    def _query_icmp_block_inversion(zone):
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--query-icmp-block-inversion"])
        return res.rc == 0

    # Helper for adding/removing
    def _add_service(zone, service, timeout):
        if timeout > 0:
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-service=" + service, "--timeout=" + str(timeout)])
        else:
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-service=" + service])

    def _add_protocol(zone, protocol, timeout):
        if timeout > 0:
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-protocol=" + protocol, "--timeout=" + str(timeout)])
        else:
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-protocol=" + protocol])

    def _add_port(zone, port, protocol, timeout):
        if timeout > 0:
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-port=" + port + "/" + protocol, "--timeout=" + str(timeout)])
        else:
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-port=" + port + "/" + protocol])

    def _add_rich_rule(zone, rule, timeout):
        if timeout > 0:
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-rich-rule", rule, "--timeout=" + str(timeout)])
        else:
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-rich-rule", rule])

    def _add_interface(zone, iface):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--change-interface=" + iface])

    def _add_masquerade(zone):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-masquerade"])

    def _add_source(zone, source_ip):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-source=" + source_ip])

    def _add_icmp_block(zone, icmp):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-icmp-block=" + icmp])

    def _add_icmp_block_inversion(zone):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--add-icmp-block-inversion"])

    def _remove_service(zone, service):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--remove-service=" + service])

    def _remove_protocol(zone, protocol):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--remove-protocol=" + protocol])

    def _remove_port(zone, port, protocol):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--remove-port=" + port + "/" + protocol])

    def _remove_rich_rule(zone, rule):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--remove-rich-rule", rule])

    def _remove_interface(zone, iface):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--remove-interface=" + iface])

    def _remove_masquerade(zone):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--remove-masquerade"])

    def _remove_source(zone, source_ip):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--remove-source=" + source_ip])

    def _remove_icmp_block(zone, icmp):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--remove-icmp-block=" + icmp])

    def _remove_icmp_block_inversion(zone):
        ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--remove-icmp-block-inversion"])

    def _set_target(zone, target_val):
        if target_val == "default":
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--set-target=default"])
        else:
            ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--set-target=" + target_val])

    # Service
    if services != None:
        enabled = _query_service(zone, services)
        if state == "enabled":
            if enabled:
                return {"changed": False, "msg": "service " + services + " already enabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable service " + services}
            _add_service(zone, services, timeout)
            return {"changed": True, "msg": "enabled service " + services}
        elif state == "disabled":
            if not enabled:
                return {"changed": False, "msg": "service " + services + " already disabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable service " + services}
            _remove_service(zone, services)
            return {"changed": True, "msg": "disabled service " + services}
        fail("unsupported state for service: " + state)

    # Protocol
    if protocols != None:
        enabled = _query_protocol(zone, protocols)
        if state == "enabled":
            if enabled:
                return {"changed": False, "msg": "protocol " + protocols + " already enabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable protocol " + protocols}
            _add_protocol(zone, protocols, timeout)
            return {"changed": True, "msg": "enabled protocol " + protocols}
        elif state == "disabled":
            if not enabled:
                return {"changed": False, "msg": "protocol " + protocols + " already disabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable protocol " + protocols}
            _remove_protocol(zone, protocols)
            return {"changed": True, "msg": "disabled protocol " + protocols}
        fail("unsupported state for protocol: " + state)

    # Port
    if ports != None:
        if "/" not in ports:
            fail("improper port format: missing protocol")
        port, protocol = ports.split("/", 1)
        enabled = _query_port(zone, port, protocol)
        if state == "enabled":
            if enabled:
                return {"changed": False, "msg": "port " + ports + " already enabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable port " + ports}
            _add_port(zone, port, protocol, timeout)
            return {"changed": True, "msg": "enabled port " + ports}
        elif state == "disabled":
            if not enabled:
                return {"changed": False, "msg": "port " + ports + " already disabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable port " + ports}
            _remove_port(zone, port, protocol)
            return {"changed": True, "msg": "disabled port " + ports}
        fail("unsupported state for port: " + state)

    # Port forwarding (only one allowed per task)
    if port_forward != None:
        if len(port_forward) != 1:
            fail("only one port forward supported at a time")
        pf = port_forward[0]
        pf_port = pf.get("port")
        pf_proto = pf.get("proto")
        pf_toport = pf.get("toport")
        pf_toaddr = pf.get("toaddr", "")

        # Query forward rule
        res = ctx.run([
            "firewall-cmd", "--permanent", "--zone=" + zone,
            "--query-forward-port=port=" + pf_port + ":proto=" + pf_proto + ":toport=" + pf_toport + ":toaddr=" + pf_toaddr
        ])
        enabled = res.rc == 0

        if state == "enabled":
            if enabled:
                return {"changed": False, "msg": "port-forward " + pf_port + "/" + pf_proto + " to " + pf_toport + " already enabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable port-forward"}
            # Build and run add command
            cmd = [
                "firewall-cmd", "--permanent", "--zone=" + zone,
                "--add-forward-port=port=" + pf_port + ":proto=" + pf_proto + ":toport=" + pf_toport + ":toaddr=" + pf_toaddr
            ]
            if timeout > 0:
                cmd.append("--timeout=" + str(timeout))
            res = ctx.run(cmd)
            if res.rc != 0:
                fail("failed to add port-forward: " + res.stderr)
            return {"changed": True, "msg": "enabled port-forward " + pf_port + "/" + pf_proto}
        elif state == "disabled":
            if not enabled:
                return {"changed": False, "msg": "port-forward already disabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable port-forward"}
            res = ctx.run([
                "firewall-cmd", "--permanent", "--zone=" + zone,
                "--remove-forward-port=port=" + pf_port + ":proto=" + pf_proto + ":toport=" + pf_toport + ":toaddr=" + pf_toaddr
            ])
            if res.rc != 0:
                fail("failed to remove port-forward: " + res.stderr)
            return {"changed": True, "msg": "disabled port-forward " + pf_port + "/" + pf_proto}
        fail("unsupported state for port-forward: " + state)

    # Rich rule
    if rich_rule != None:
        enabled = _query_rich_rule(zone, rich_rule)
        if state == "enabled":
            if enabled:
                return {"changed": False, "msg": "rich rule already enabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable rich rule"}
            _add_rich_rule(zone, rich_rule, timeout)
            return {"changed": True, "msg": "enabled rich rule"}
        elif state == "disabled":
            if not enabled:
                return {"changed": False, "msg": "rich rule already disabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable rich rule"}
            _remove_rich_rule(zone, rich_rule)
            return {"changed": True, "msg": "disabled rich rule"}
        fail("unsupported state for rich_rule: " + state)

    # Interface
    if interface != None:
        enabled = _query_interface(zone, interface)
        if state == "enabled":
            if enabled:
                return {"changed": False, "msg": "interface " + interface + " already in zone " + zone}
            if ctx.check_mode:
                return {"changed": True, "msg": "would move interface " + interface + " to zone " + zone}
            _add_interface(zone, interface)
            return {"changed": True, "msg": "moved interface " + interface + " to zone " + zone}
        elif state == "disabled":
            if not enabled:
                return {"changed": False, "msg": "interface " + interface + " not in zone " + zone}
            if ctx.check_mode:
                return {"changed": True, "msg": "would remove interface " + interface + " from zone " + zone}
            _remove_interface(zone, interface)
            return {"changed": True, "msg": "removed interface " + interface + " from zone " + zone}
        fail("unsupported state for interface: " + state)

    # Masquerade (string -> boolean coercion)
    if masquerade != None:
        # Accept "true"/"false" strings; default to True if present
        masq_bool = masquerade in ["true", "True", True]
        enabled = _query_masquerade(zone)
        desired_enabled = masq_bool and state == "enabled"
        desired_disabled = not masq_bool and state == "disabled"
        if desired_enabled:
            if enabled:
                return {"changed": False, "msg": "masquerade already enabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable masquerade"}
            _add_masquerade(zone)
            return {"changed": True, "msg": "enabled masquerade"}
        elif desired_disabled:
            if not enabled:
                return {"changed": False, "msg": "masquerade already disabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable masquerade"}
            _remove_masquerade(zone)
            return {"changed": True, "msg": "disabled masquerade"}
        fail("unsupported masquerade/state combination")

    # Source
    if source != None:
        enabled = _query_source(zone, source)
        if state == "enabled":
            if enabled:
                return {"changed": False, "msg": "source " + source + " already in zone " + zone}
            if ctx.check_mode:
                return {"changed": True, "msg": "would add source " + source}
            _add_source(zone, source)
            return {"changed": True, "msg": "added source " + source}
        elif state == "disabled":
            if not enabled:
                return {"changed": False, "msg": "source " + source + " not in zone " + zone}
            if ctx.check_mode:
                return {"changed": True, "msg": "would remove source " + source}
            _remove_source(zone, source)
            return {"changed": True, "msg": "removed source " + source}
        fail("unsupported state for source: " + state)

    # ICMP block
    if icmp_block != None:
        enabled = _query_icmp_block(zone, icmp_block)
        if state == "enabled":
            if enabled:
                return {"changed": False, "msg": "icmp-block " + icmp_block + " already enabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable icmp-block " + icmp_block}
            _add_icmp_block(zone, icmp_block)
            return {"changed": True, "msg": "enabled icmp-block " + icmp_block}
        elif state == "disabled":
            if not enabled:
                return {"changed": False, "msg": "icmp-block " + icmp_block + " already disabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable icmp-block " + icmp_block}
            _remove_icmp_block(zone, icmp_block)
            return {"changed": True, "msg": "disabled icmp-block " + icmp_block}
        fail("unsupported state for icmp_block: " + state)

    # ICMP block inversion (string -> boolean coercion)
    if icmp_block_inversion != None:
        inv_bool = icmp_block_inversion in ["true", "True", True]
        enabled = _query_icmp_block_inversion(zone)
        desired_enabled = inv_bool and state == "enabled"
        desired_disabled = not inv_bool and state == "disabled"
        if desired_enabled:
            if enabled:
                return {"changed": False, "msg": "icmp-block-inversion already enabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable icmp-block-inversion"}
            _add_icmp_block_inversion(zone)
            return {"changed": True, "msg": "enabled icmp-block-inversion"}
        elif desired_disabled:
            if not enabled:
                return {"changed": False, "msg": "icmp-block-inversion already disabled"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable icmp-block-inversion"}
            _remove_icmp_block_inversion(zone)
            return {"changed": True, "msg": "disabled icmp-block-inversion"}
        fail("unsupported icmp_block_inversion/state combination")

    # Target
    if target != None:
        res = ctx.run(["firewall-cmd", "--permanent", "--zone=" + zone, "--get-target"])
        current_target = res.stdout.strip()
        if state == "enabled":
            if target == current_target:
                return {"changed": False, "msg": "zone target already set to " + target}
            if ctx.check_mode:
                return {"changed": True, "msg": "would set zone target to " + target}
            _set_target(zone, target)
            return {"changed": True, "msg": "set zone target to " + target}
        elif state == "disabled":
            if target != "default":
                fail("state 'disabled' only valid for resetting target to default")
            if current_target == "default":
                return {"changed": False, "msg": "zone target already default"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would reset zone target to default"}
            _set_target(zone, "default")
            return {"changed": True, "msg": "reset zone target to default"}
        fail("unsupported state for target: " + state)

    # Fallback
    fail("no recognized parameter provided for action")
