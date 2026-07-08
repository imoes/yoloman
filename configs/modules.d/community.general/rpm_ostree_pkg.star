def main(ctx, params):
    pkgs = params["name"]
    state = params.get("state", "present")
    
    if type(pkgs) == "string":
        pkgs = [pkgs]
    if type(pkgs) != "list" or len(pkgs) == 0:
        fail("name must be a non-empty list of strings")

    # Build rpm-ostree command
    rpm_ostree = ctx.run(["which", "rpm-ostree"], mutates=False)
    if rpm_ostree.rc != 0:
        fail("rpm-ostree command not found")

    cmd_base = ["/usr/bin/rpm-ostree"]
    action = ""
    
    if state == "present":
        action = "install"
        cmd_base.extend(["install", "--allow-inactive", "--idempotent", "--unchanged-exit-77"])
    elif state == "absent":
        action = "uninstall"
        cmd_base.extend(["uninstall", "--allow-inactive", "--idempotent", "--unchanged-exit-77"])
    else:
        fail("unsupported state: " + state)

    cmd = cmd_base + pkgs

    # Check current state (read-only probe)
    status_cmd = cmd_base[:2] + ["status", "--json"]
    status_res = ctx.run(status_cmd, mutates=False)
    
    installed_pkgs = []
    if status_res.rc == 0:
        # Simple parsing of rpm-ostree status output
        lines = status_res.stdout.splitlines()
        in_packages = False
        for line in lines:
            stripped = line.strip()
            if stripped.startswith('"packages":'):
                in_packages = True
                continue
            if in_packages:
                if stripped == "]":
                    break
                # Extract package name from lines like: "nfs-utils-1.3.4-9.el8"
                pkg_line = stripped.strip('" ,')
                if pkg_line:
                    # Split by '-' and take first part; handle cases with epoch
                    parts = pkg_line.split("-")
                    pkg_name = parts[0]
                    installed_pkgs.append(pkg_name)

    # Determine if action is needed
    needed = False
    if state == "present":
        for pkg in pkgs:
            if pkg not in installed_pkgs:
                needed = True
                break
    elif state == "absent":
        for pkg in pkgs:
            if pkg in installed_pkgs:
                needed = True
                break
    
    if not needed:
        return {
            "changed": False,
            "rc": 0,
            "action": action,
            "packages": pkgs,
            "stdout": "",
            "stderr": "",
            "cmd": " ".join(cmd)
        }

    if ctx.check_mode:
        return {
            "changed": True,
            "rc": 0,
            "action": action,
            "packages": pkgs,
            "stdout": "",
            "stderr": "",
            "msg": "would " + action + " " + ", ".join(pkgs)
        }

    # Execute the rpm-ostree command
    res = ctx.run(cmd, mutates=True)
    
    # Handle the exit codes per original behavior:
    # rc=0: succeeded in making a change
    # rc=77: no change was needed
    if res.rc == 0:
        return {
            "changed": True,
            "rc": res.rc,
            "action": action,
            "packages": pkgs,
            "stdout": res.stdout,
            "stderr": res.stderr,
            "cmd": " ".join(cmd)
        }
    elif res.rc == 77:
        return {
            "changed": False,
            "rc": 0,
            "action": action,
            "packages": pkgs,
            "stdout": res.stdout,
            "stderr": res.stderr,
            "cmd": " ".join(cmd)
        }
    else:
        fail("rpm-ostree " + action + " failed: " + res.stderr)
