def main(ctx, params):
    # Get parameters
    portal = params.get("portal")
    port = params.get("port", "3260")
    target = params.get("target")
    node_auth = params.get("node_auth", "CHAP")
    node_user = params.get("node_user")
    node_pass = params.get("node_pass")
    node_user_in = params.get("node_user_in")
    node_pass_in = params.get("node_pass_in")
    login = params.get("login")  # bool or None
    auto_node_startup = params.get("auto_node_startup")
    auto_portal_startup = params.get("auto_portal_startup")
    discover = params.get("discover", False)
    show_nodes = params.get("show_nodes", False)
    rescan = params.get("rescan", False)

    # Check required combinations
    if node_user != None and node_pass == None:
        fail("node_pass is required when node_user is specified")
    if node_pass != None and node_user == None:
        fail("node_user is required when node_pass is specified")
    if node_user_in != None and node_pass_in == None:
        fail("node_pass_in is required when node_user_in is specified")
    if node_pass_in != None and node_user_in == None:
        fail("node_user_in is required when node_pass_in is specified")

    if discover and portal == None:
        fail("portal is required when discover is true")

    # Get portal IP if needed (simple lookup via getaddrinfo replacement)
    if portal != None:
        # Try to resolve the hostname to IP using ctx.run
        res = ctx.run(["getent", "hosts", portal])
        if res.rc == 0:
            # Parse output: "1.2.3.4 hostname" or "ipv6 hostname"
            line = res.stdout.strip()
            portal = line.split()[0]
        else:
            fail("Portal address is incorrect: " + portal)

    # Build target node key: "ip,port,target"
    if portal == None:
        portal = ""
    if target == None:
        target = ""

    # Check iscsiadm exists
    res = ctx.run(["which", "iscsiadm"])
    if res.rc != 0:
        fail("iscsiadm not found")

    def run_iscsiadm(argv, check_rc=False, mutates=False):
        full = ["iscsiadm"] + argv
        res = ctx.run(full, mutates=mutates)
        if check_rc and res.rc != 0:
            fail("iscsiadm failed: " + res.stderr)
        return res

    # Get cached nodes
    def get_cached_nodes(portal_filter=None):
        res = run_iscsiadm(["--mode", "node"])
        if res.rc == 0:
            nodes = []
            for line in res.stdout.strip().splitlines():
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) < 2:
                    continue
                target_name = parts[1]
                ip_part = parts[0].split(":")[0]
                if portal_filter == None or portal_filter == ip_part:
                    nodes.append(target_name)
            return nodes
        # rc == 21 or "no records" error => empty list
        return []

    # Discover targets
    def discover_targets():
        run_iscsiadm(
            ["--mode", "discovery", "--type", "sendtargets", "--portal", portal + ":" + port],
            check_rc=True,
            mutates=True,
        )

    # Check if target is logged in
    def target_loggedon(target_name, portal_arg=None, port_arg=None):
        res = run_iscsiadm(["--mode", "session"])
        if res.rc == 0:
            # Format: "tcp: [10.1.2.3:3260,1] iqn.target"
            search_str = (portal_arg or "") + ":" + (port_arg or "") + ".*" + target_name
            for line in res.stdout.splitlines():
                if search_str in line:
                    return True
            return False
        return False

    # Login/logout
    def login_target():
        if node_user != None and node_pass != None:
            run_iscsiadm(
                ["--mode", "node", "--targetname", target, "--op=update", "--name", "node.session.auth.authmethod", "--value", node_auth],
                check_rc=True,
                mutates=True,
            )
            run_iscsiadm(
                ["--mode", "node", "--targetname", target, "--op=update", "--name", "node.session.auth.username", "--value", node_user],
                check_rc=True,
                mutates=True,
            )
            run_iscsiadm(
                ["--mode", "node", "--targetname", target, "--op=update", "--name", "node.session.auth.password", "--value", node_pass],
                check_rc=True,
                mutates=True,
            )
        if node_user_in != None and node_pass_in != None:
            run_iscsiadm(
                ["--mode", "node", "--targetname", target, "--op=update", "--name", "node.session.auth.username_in", "--value", node_user_in],
                check_rc=True,
                mutates=True,
            )
            run_iscsiadm(
                ["--mode", "node", "--targetname", target, "--op=update", "--name", "node.session.auth.password_in", "--value", node_pass_in],
                check_rc=True,
                mutates=True,
            )
        cmd = ["--mode", "node", "--targetname", target, "--login"]
        if portal != "" and port != "":
            cmd.extend(["--portal", portal + ":" + port])
        run_iscsiadm(cmd, check_rc=True, mutates=True)

    def logout_target():
        cmd = ["--mode", "node", "--targetname", target, "--logout"]
        if portal != "" and port != "":
            cmd.extend(["--portal", portal + ":" + port])
        run_iscsiadm(cmd, check_rc=True, mutates=True)

    # Auto startup helpers
    def is_auto(target_name, portal_arg=None, port_arg=None):
        cmd = ["--mode", "node", "--targetname", target_name]
        if portal_arg != None and port_arg != None:
            cmd.extend(["--portal", portal_arg + ":" + port_arg])
        res = run_iscsiadm(cmd)
        if res.rc != 0:
            return False
        for line in res.stdout.splitlines():
            if "node.startup" in line:
                return "automatic" in line
        return False

    def set_auto(target_name, portal_arg=None, port_arg=None):
        cmd = ["--mode", "node", "--targetname", target_name, "--op=update", "--name", "node.startup", "--value", "automatic"]
        if portal_arg != None and port_arg != None:
            cmd.extend(["--portal", portal_arg + ":" + port_arg])
        run_iscsiadm(cmd, check_rc=True, mutates=True)

    def set_manual(target_name, portal_arg=None, port_arg=None):
        cmd = ["--mode", "node", "--targetname", target_name, "--op=update", "--name", "node.startup", "--value", "manual"]
        if portal_arg != None and port_arg != None:
            cmd.extend(["--portal", portal_arg + ":" + port_arg])
        run_iscsiadm(cmd, check_rc=True, mutates=True)

    # Rescan
    def do_rescan(target_name=None):
        if target_name == None:
            res = run_iscsiadm(["--mode", "session", "--rescan"])
        else:
            res = run_iscsiadm(["--mode", "node", "--rescan", "-T", target_name])
        return res.stdout.strip()

    # Start logic
    changed = False
    msg = ""

    # Discovery
    if discover:
        if ctx.check_mode:
            # Predict: discovery will change cache if portal differs or new targets appear
            cached = get_cached_nodes(portal if portal != "" else None)
            # Simulate discovery by just noting it would change
            changed = True
            msg = "would discover targets on " + portal + ":" + port
        else:
            discover_targets()
            nodes = get_cached_nodes(portal if portal != "" else None)
            cached = get_cached_nodes(portal if portal != "" else None)
            if len(nodes) > len(cached):
                changed = True
                msg = "discovered new targets"
            else:
                msg = "discovery completed (no new targets)"
    else:
        cached = get_cached_nodes(portal if portal != "" else None)

    # Show nodes
    nodes_result = cached

    # Login/Logout
    if login != None:
        if target == None:
            if len(nodes_result) == 0:
                fail("No target found and target not specified")
            if len(nodes_result) > 1:
                fail("Multiple targets found; specify target")
            target = nodes_result[0]
        else:
            # Validate target is in cache
            if target not in nodes_result:
                fail("Specified target not found in cache")

        # Get current login state
        loggedon = target_loggedon(target, portal, port)

        if (login and loggedon) or (not login and not loggedon):
            changed = changed or False
            msg = "connection state already correct"
        else:
            if ctx.check_mode:
                changed = True
                msg = "would " + ("connect to" if login else "disconnect from") + " target"
            else:
                if login:
                    login_target()
                    msg = "connected to target"
                else:
                    logout_target()
                    msg = "disconnected from target"
                changed = True

    # Auto node startup
    if auto_node_startup != None:
        if target == None and len(nodes_result) > 0:
            target = nodes_result[0]
        if target == "":
            fail("target required for auto_node_startup")

        current_auto = is_auto(target, None, None)
        if (auto_node_startup and current_auto) or (not auto_node_startup and not current_auto):
            # Already correct
            pass
        else:
            if ctx.check_mode:
                changed = True
                msg = "would update auto_node_startup"
            else:
                if auto_node_startup:
                    set_auto(target)
                else:
                    set_manual(target)
                changed = True
                msg = "updated auto_node_startup"

    # Auto portal startup
    if auto_portal_startup != None:
        if target == "" or portal == "":
            fail("target and portal required for auto_portal_startup")

        current_auto = is_auto(target, portal, port)
        if (auto_portal_startup and current_auto) or (not auto_portal_startup and not current_auto):
            # Already correct
            pass
        else:
            if ctx.check_mode:
                changed = True
                msg = "would update auto_portal_startup"
            else:
                if auto_portal_startup:
                    set_auto(target, portal, port)
                else:
                    set_manual(target, portal, port)
                changed = True
                msg = "updated auto_portal_startup"

    # Rescan
    if rescan:
        if ctx.check_mode:
            changed = True
            msg = "would rescan sessions"
        else:
            output = do_rescan(target if target != "" else None)
            changed = True
            msg = "rescan completed"

    # Final return
    result = {
        "changed": changed,
        "msg": msg,
        "nodes": nodes_result if show_nodes else None
    }
    # Filter out null keys for cleaner output
    final = {}
    for k, v in result.items():
        if v != None:
            final[k] = v
    return final
