def main(ctx, params):
    # Map aliases and defaults
    name = params.get("name", [])
    if isinstance(name, str):
        name = [name]
    selfupdate = params.get("selfupdate", False)
    state = params.get("state", "present")
    upgrade = params.get("upgrade", False)
    variant = params.get("variant", None)

    # Validate state + variant combination
    if variant != None and state not in ("present", "installed"):
        fail("variant is only supported with state=present or state=installed")

    port_path = "/opt/local/bin/port"
    # Check port binary exists
    res = ctx.run(["test", "-x", port_path], mutates=False)
    if res.rc != 0:
        fail("port binary not found at " + port_path + " or not executable")

    stdout = ""
    stderr = ""

    # Handle selfupdate
    if selfupdate:
        res = ctx.run([port_path, "-v", "selfupdate"], mutates=False)
        stdout += res.stdout
        stderr += res.stderr

        updated = False
        for line in res.stdout.split("\n"):
            stripped = line.strip()
            if "Total number of ports parsed:" in stripped and "0" not in stripped:
                updated = True
            if "Installing new Macports release" in stripped:
                updated = True

        changed = True
        msg = "Macports updated successfully" if updated else "Macports already up-to-date"

        if not name and not upgrade:
            return {"changed": changed, "msg": msg, "stdout": stdout, "stderr": stderr}
        if not ctx.check_mode and updated:
            # If updated, re-run the rest
            pass
        elif not ctx.check_mode and not updated:
            pass

    # Handle upgrade
    if upgrade:
        res = ctx.run([port_path, "upgrade", "outdated"], mutates=False)
        stdout += res.stdout
        stderr += res.stderr

        if res.stdout.strip() == "Nothing to upgrade.":
            changed = False
            msg = "Ports already upgraded"
        elif res.rc == 0:
            changed = True
            msg = "Outdated ports upgraded successfully"
        else:
            fail("Failed to upgrade outdated ports: " + res.stderr)

        if not name:
            return {"changed": changed, "msg": msg, "stdout": stdout, "stderr": stderr}

    # Process package state
    changed = False
    msg = ""

    def port_installed(port):
        res = ctx.run([port_path, "-q", "installed", port], mutates=False)
        if res.rc == 0 and res.stdout.strip().startswith(port + " "):
            return True
        return False

    def port_active(port):
        res = ctx.run([port_path, "-q", "installed", port], mutates=False)
        if res.rc == 0 and "(active)" in res.stdout:
            return True
        return False

    # State handling
    if state in ("present", "installed"):
        count = 0
        for pkg in name:
            if port_installed(pkg):
                continue
            if ctx.check_mode:
                changed = True
                continue
            res = ctx.run([port_path, "install", pkg] + ([variant] if variant else []), mutates=True)
            stdout += res.stdout
            stderr += res.stderr
            if res.rc != 0 or not port_installed(pkg):
                fail("Failed to install %s: %s" % (pkg, res.stderr))
            count += 1
            changed = True
        if count > 0:
            msg = "Installed %s port(s)" % count
        else:
            msg = "Port(s) already present"

    elif state in ("absent", "removed"):
        count = 0
        for pkg in name:
            if not port_installed(pkg):
                continue
            if ctx.check_mode:
                changed = True
                continue
            res = ctx.run([port_path, "uninstall", pkg], mutates=True)
            stdout += res.stdout
            stderr += res.stderr
            if port_installed(pkg):
                fail("Failed to remove %s: %s" % (pkg, res.stderr))
            count += 1
            changed = True
        if count > 0:
            msg = "Removed %s port(s)" % count
        else:
            msg = "Port(s) already absent"

    elif state == "active":
        count = 0
        for pkg in name:
            if not port_installed(pkg):
                fail("Failed to activate %s, port not present" % pkg)
            if port_active(pkg):
                continue
            if ctx.check_mode:
                changed = True
                continue
            res = ctx.run([port_path, "activate", pkg], mutates=True)
            stdout += res.stdout
            stderr += res.stderr
            if not port_active(pkg):
                fail("Failed to activate %s: %s" % (pkg, res.stderr))
            count += 1
            changed = True
        if count > 0:
            msg = "Activated %s port(s)" % count
        else:
            msg = "Port(s) already active"

    elif state == "inactive":
        count = 0
        for pkg in name:
            if not port_installed(pkg):
                fail("Failed to deactivate %s, port not present" % pkg)
            if not port_active(pkg):
                continue
            if ctx.check_mode:
                changed = True
                continue
            res = ctx.run([port_path, "deactivate", pkg], mutates=True)
            stdout += res.stdout
            stderr += res.stderr
            if port_active(pkg):
                fail("Failed to deactivate %s: %s" % (pkg, res.stderr))
            count += 1
            changed = True
        if count > 0:
            msg = "Deactivated %s port(s)" % count
        else:
            msg = "Port(s) already inactive"

    else:
        fail("unsupported state: " + state)

    return {"changed": changed, "msg": msg, "stdout": stdout, "stderr": stderr}
