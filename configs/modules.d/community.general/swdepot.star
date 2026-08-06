def main(ctx, params):
    name = params["name"]
    state = params["state"]
    depot = params.get("depot")

    # Validate state and depot requirement
    if state in ("present", "latest") and depot == None:
        fail("depot parameter is mandatory in present or latest task")

    # Query installed version (read-only)
    cmd_list = ["/usr/sbin/swlist", "-a", "revision", "-l", "product"]
    if depot != None:
        cmd = cmd_list + ["-s", depot, name]
    else:
        cmd = cmd_list + [name]
    res = ctx.run(cmd, ok_codes=[0, 1])
    installed = False
    installed_version = None
    if res.rc == 0:
        lines = res.stdout.splitlines()
        for line in lines:
            # Match lines like: "name       1.2.3"
            parts = line.split()
            if len(parts) >= 2 and parts[0] == name:
                installed = True
                installed_version = parts[1]
                break

    # Compare versions (simple string-based for Starlark; fallback to numeric if possible)
    def compare_version(v1, v2):
        # Normalize: strip trailing .0s
        def normalize(v):
            # Remove trailing '.0' components
            parts = v.split(".")
            while len(parts) > 0 and parts[-1] == "0":
                parts.pop()
            if len(parts) == 0:
                return [0]
            # Convert to ints only if numeric
            result = []
            for p in parts:
                if p.isdigit() or (p.startswith("-") and p[1:].isdigit()):
                    result.append(int(p))
                else:
                    return None
            return result
        nv1 = normalize(v1)
        nv2 = normalize(v2)
        if nv1 == None or nv2 == None:
            # Fallback: string comparison (lexicographic)
            if v1 < v2: return -1
            if v1 > v2: return 1
            return 0
        # Compare numeric lists
        for i in range(max(len(nv1), len(nv2))):
            a = nv1[i] if i < len(nv1) else 0
            b = nv2[i] if i < len(nv2) else 0
            if a < b: return -1
            if a > b: return 1
        return 0

    # State: absent
    if state == "absent":
        if not installed:
            return {"changed": False, "msg": "Package not installed"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove " + name}
        res = ctx.run(["/usr/sbin/swremove", name], mutates=True, ok_codes=[0])
        if res.skipped:
            return {"changed": True, "msg": "would remove " + name}
        if res.rc != 0:
            fail("failed to remove " + name + ": " + res.stderr)
        return {"changed": True, "msg": "Package removed"}

    # State: present or latest
    # Check if depot is required
    if state == "present" and depot == None:
        fail("depot parameter is mandatory in present or latest task")

    # Query depot version (only if needed)
    depot_version = None
    if state == "latest" or (state == "present" and installed):
        # Query remote version
        cmd = ["/usr/sbin/swlist", "-a", "revision", "-l", "product", "-s", depot, name]
        res = ctx.run(cmd, ok_codes=[0, 1])
        if res.rc != 0:
            fail("Software package not in repository " + depot)
        # Parse output
        lines = res.stdout.splitlines()
        for line in lines:
            parts = line.split()
            if len(parts) >= 2 and parts[0] == name:
                depot_version = parts[1]
                break
        if depot_version == None:
            fail("Software package not in repository " + depot)

    # State: present (and not installed)
    if state == "present" and not installed:
        if ctx.check_mode:
            return {"changed": True, "msg": "would install " + name}
        res = ctx.run(["/usr/sbin/swinstall", "-x", "mount_all_filesystems=false", "-s", depot, name], mutates=True, ok_codes=[0])
        if res.skipped:
            return {"changed": True, "msg": "would install " + name}
        if res.rc != 0:
            fail("failed to install " + name + ": " + res.stderr)
        return {"changed": True, "msg": "Package installed"}

    # State: latest
    if state == "latest":
        if not installed:
            # Same as present install (but state is latest)
            if ctx.check_mode:
                return {"changed": True, "msg": "would install " + name}
            res = ctx.run(["/usr/sbin/swinstall", "-x", "mount_all_filesystems=false", "-s", depot, name], mutates=True, ok_codes=[0])
            if res.skipped:
                return {"changed": True, "msg": "would install " + name}
            if res.rc != 0:
                fail("failed to install " + name + ": " + res.stderr)
            return {"changed": True, "msg": "Package installed"}

        # Installed: compare versions
        cmp_result = compare_version(installed_version, depot_version)
        if cmp_result >= 0:
            return {"changed": False, "msg": "Package already at latest version"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would upgrade " + name}
        res = ctx.run(["/usr/sbin/swinstall", "-x", "mount_all_filesystems=false", "-s", depot, name], mutates=True, ok_codes=[0])
        if res.skipped:
            return {"changed": True, "msg": "would upgrade " + name}
        if res.rc != 0:
            fail("failed to upgrade " + name + ": " + res.stderr)
        return {"changed": True, "msg": "Package upgraded, Before %s Now %s" % (installed_version, depot_version)}

    return {"changed": False, "msg": "No changes required"}
