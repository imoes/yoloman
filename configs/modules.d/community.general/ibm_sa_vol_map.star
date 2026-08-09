def main(ctx, params):
    endpoints = params.get("endpoints")
    username = params.get("username")
    password = params.get("password")
    vol = params.get("vol")
    state = params.get("state", "present")
    host = params.get("host")
    cluster = params.get("cluster")
    lun = params.get("lun")
    override = params.get("override")

    if not endpoints or not username or not password or not vol:
        fail("missing required parameters: endpoints, username, password, vol")

    # Build CLI command base
    # We assume the 'ibmsvc' or 'svccli' command is available (standard for IBM Spectrum Accelerate)
    # Check for mapping by running: svcinfo command
    base_cmd = ["svcinfo", "volmaplist", "-object", vol]
    if host:
        base_cmd.extend(["-host", host])
    if cluster:
        fail("cluster parameter is not supported in current implementation")

    # Probe mapping state (read-only)
    res = ctx.run(base_cmd)
    if res.rc != 0 and "No matching objects were found" not in res.stderr:
        # Non-zero rc other than "not found" is unexpected
        fail("failed to list volume mappings: " + res.stderr)
    
    mapping_exists = res.rc == 0 and len(res.stdout.strip()) > 0

    if state == "present":
        if mapping_exists:
            return {"changed": False, "msg": "volume " + vol + " already mapped"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would map volume " + vol + " to host " + (host or "unknown")}
        
        # Build map command
        cmd = ["svcmap", "-object", vol]
        if host:
            cmd.extend(["-host", host])
        else:
            fail("host parameter is required when state=present")
        if lun:
            cmd.extend(["- lun", lun])
        if override:
            cmd.append("-override")

        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would map volume " + vol}
        if res.rc != 0:
            fail("failed to map volume: " + res.stderr)
        return {"changed": True, "msg": "mapped volume " + vol}

    if state == "absent":
        if not mapping_exists:
            return {"changed": False, "msg": "volume " + vol + " not mapped"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would unmap volume " + vol}
        
        cmd = ["svcunmap", "-object", vol]
        if host:
            cmd.extend(["-host", host])
        
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would unmap volume " + vol}
        if res.rc != 0:
            fail("failed to unmap volume: " + res.stderr)
        return {"changed": True, "msg": "unmapped volume " + vol}

    fail("unsupported state: " + state)
