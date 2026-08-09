def main(ctx, params):
    ignore_selinux_state = params.get("ignore_selinux_state", False)
    ports = params["ports"]
    proto = params["proto"]
    setype = params["setype"]
    state = params.get("state", "present")
    do_reload = params.get("reload", True)
    local = params.get("local", False)

    # SELinux check
    res = ctx.run(["getenforce"], mutates=False)
    if res.rc != 0 or res.stdout.strip() != "Enforcing":
        if not ignore_selinux_state:
            fail("SELinux is disabled on this host.")

    # Validate proto
    if proto not in ["tcp", "udp"]:
        fail("Invalid protocol: %s (must be tcp or udp)" % proto)

    # Parse ports: ensure list of strings
    if type(ports) == "string":
        ports = [p.strip() for p in ports.split(",") if p.strip()]
    elif type(ports) == "list":
        for p in ports:
            if type(p) != "string":
                fail("Each port must be a string, got %s" % type(p))
    else:
        fail("ports must be a string or list of strings")

    # Check required modules via run (no imports possible)
    res = ctx.run(["which", "semodule"], mutates=False)
    if res.rc != 0:
        fail("semodule not found — policycoreutils-python is not installed")
    res = ctx.run(["which", "semanage"], mutates=False)
    if res.rc != 0:
        fail("semanage not found — policycoreutils-python is not installed")

    # Build semanage command parts
    cmd_base = ["semanage", "port"]
    if local:
        cmd_base.append("-L")
    cmd_base.extend(["-p", proto, "-t", setype])

    # Determine current ports for the type+proto
    # Using semanage port list and filtering
    res = ctx.run(["semanage", "port", "-l"], mutates=False)
    if res.rc != 0:
        fail("Failed to list current ports: %s" % res.stderr)

    # Build expected set of ports to query
    ports_to_check = set(ports)

    # Parse output to find current type assignments for given proto
    current_ports_by_type = {}  # dict[str, list[str]]
    lines = res.stdout.splitlines()
    header_found = False
    for line in lines:
        if "tcp" in line or "udp" in line:
            # Skip empty lines
            if line.strip() == "":
                continue
            parts = line.split()
            if len(parts) >= 3:
                # Format: proto  port_type  ports(s)
                p_proto, p_type, p_ports = parts[0], parts[1], parts[2]
                # Normalize proto (selinux uses tcp/udp, not tcp/udp)
                if p_proto not in ["tcp", "udp"]:
                    continue
                if p_type not in current_ports_by_type:
                    current_ports_by_type[p_type] = []
                # Parse port range(s) — may be comma-separated ranges
                for pr in p_ports.split(","):
                    # pr can be like "8080", "8080-9090"
                    current_ports_by_type[p_type].append(pr)

    # Get currently assigned ports for our setype+proto
    current_ports = current_ports_by_type.get(setype, [])
    current_set = set(current_ports)

    # Determine desired state
    if state == "present":
        # Ports that need to be added
        missing = ports_to_check - current_set
        if len(missing) == 0:
            return {"changed": False, "msg": "All ports already set to type %s" % setype}
        # In check mode, report change
        if ctx.check_mode:
            return {"changed": True, "msg": "would add ports %s to type %s" % (",".join(missing), setype)}
        # Add missing ports one by one
        for port in missing:
            cmd = cmd_base + [port]
            res = ctx.run(cmd)
            if res.rc != 0:
                fail("Failed to add port %s: %s" % (port, res.stderr))
        if do_reload:
            res = ctx.run(["semodule", "-r", "base"], mutates=True)
            if res.rc != 0:
                fail("Failed to reload policy: %s" % res.stderr)
        return {"changed": True, "msg": "Added ports %s to type %s" % (",".join(missing), setype)}

    elif state == "absent":
        # Ports that need to be removed
        existing = ports_to_check & current_set
        if len(existing) == 0:
            return {"changed": False, "msg": "No ports of type %s to remove" % setype}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove ports %s from type %s" % (",".join(existing), setype)}
        for port in existing:
            cmd = cmd_base + ["-d", port]
            res = ctx.run(cmd)
            if res.rc != 0:
                fail("Failed to delete port %s: %s" % (port, res.stderr))
        if do_reload:
            res = ctx.run(["semodule", "-r", "base"], mutates=True)
            if res.rc != 0:
                fail("Failed to reload policy: %s" % res.stderr)
        return {"changed": True, "msg": "Removed ports %s from type %s" % (",".join(existing), setype)}

    else:
        fail("Invalid state: %s (must be present or absent)" % state)
