def main(ctx, params):
    host = params["host"]
    state = params.get("state", "present")
    username = params["username"]
    password = params["password"]
    endpoints = params["endpoints"]
    fcaddress = params.get("fcaddress")
    iscsi_name = params.get("iscsi_name")
    num_of_visible_targets = params.get("num_of_visible_targets")

    if not fcaddress and not iscsi_name:
        fail("At least one of fcaddress or iscsi_name must be provided")

    # Build the command for listing host ports
    list_cmd = [
        "svcinfo", "lshostport", "-host", host,
        "-field", "port_name"
    ]

    # Probe current state (read-only)
    res = ctx.run(list_cmd)
    if res.rc != 0:
        fail("failed to list host ports: " + res.stderr)

    # Parse port names (strip empty lines)
    current_ports = []
    lines = res.stdout.strip().split("\n")
    for line in lines:
        stripped = line.strip()
        if stripped != "":
            current_ports.append(stripped)

    # Target ports to manage
    target_ports = []
    if iscsi_name:
        target_ports.append(iscsi_name)
    if fcaddress:
        target_ports.append(fcaddress)

    # Determine if any target port is already present
    port_exists = False
    for p in target_ports:
        for cp in current_ports:
            if p == cp:
                port_exists = True
                break
        if port_exists:
            break

    if state == "present":
        if port_exists:
            return {"changed": False, "msg": "ports already present on host " + host}
        if ctx.check_mode:
            return {"changed": True, "msg": "would add port(s) to host " + host}
        # Build add command
        add_cmd = ["svcconfig", "addhostport", "-host", host]
        if iscsi_name:
            add_cmd.extend(["-iscsiname", iscsi_name])
        if fcaddress:
            add_cmd.extend(["-fcaddress", fcaddress])
        if num_of_visible_targets:
            add_cmd.extend(["-visible_targets", num_of_visible_targets])
        res = ctx.run(add_cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would add port(s) to host " + host}
        if res.rc != 0:
            fail("failed to add port(s) to host " + host + ": " + res.stderr)
        return {"changed": True, "msg": "added port(s) to host " + host}

    elif state == "absent":
        if not port_exists:
            return {"changed": False, "msg": "port(s) not present on host " + host}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove port(s) from host " + host}
        # Build remove command
        remove_cmd = ["svcconfig", "rmhostport", "-host", host]
        if iscsi_name:
            remove_cmd.extend(["-iscsiname", iscsi_name])
        if fcaddress:
            remove_cmd.extend(["-fcaddress", fcaddress])
        res = ctx.run(remove_cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove port(s) from host " + host}
        if res.rc != 0:
            fail("failed to remove port(s) from host " + host + ": " + res.stderr)
        return {"changed": True, "msg": "removed port(s) from host " + host}

    fail("unsupported state: " + state)
