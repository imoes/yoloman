def main(ctx, params):
    # Validate and normalize inputs
    pkgs = params["name"]
    if type(pkgs) != "list":
        fail("name must be a list of package names")
    for p in pkgs:
        if type(p) != "string":
            fail("all package names must be strings, got: %s" % str(type(p)))

    state = params.get("state", "present")
    if state not in ["present", "absent", "latest", "installed", "removed"]:
        fail("unsupported state: %s" % state)
    # Alias handling
    if state == "installed":
        state = "present"
    elif state == "removed":
        state = "absent"

    update_cache = params.get("update_cache", False)

    # Check mode support
    check_mode = ctx.check_mode

    # Locate slackpkg binary
    res = ctx.run(["which", "slackpkg"])
    if res.rc != 0:
        fail("slackpkg binary not found in PATH")
    slackpkg_path = res.stdout.strip()

    # Update package cache if requested
    if update_cache:
        res = ctx.run([slackpkg_path, "-batch=on", "update"])
        if res.rc != 0:
            fail("failed to update package cache: " + res.stderr)

    # Helper: query if a package is installed
    # We simulate this by checking /var/log/packages, which requires running
    # a shell command to list files and grep.
    def package_is_installed(pkg_name):
        # Get architecture (fallback to 'x86' for x86_64 kernel-headers)
        arch = ctx.facts().get("architecture", "x86_64")
        if pkg_name == "kernel-headers" and arch == "x86_64":
            arch = "x86"
        # Pattern: pkg_name-version-arch-foo
        # Use shell to list packages and match pattern
        cmd = [
            "bash", "-c",
            ("ls /var/log/packages 2>/dev/null | grep -E '^%s-[0-9][^-]*-((%s)|noarch|fw)-' | wc -l" %
             (pkg_name.replace("\\", "\\\\").replace("$", "\\$"), arch))
        ]
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("failed to query package: " + pkg_name)
        count = int(res.stdout.strip())
        return count > 0

    changed = False
    msg = ""

    if state == "present":
        to_install = []
        for pkg in pkgs:
            if not package_is_installed(pkg):
                to_install.append(pkg)
        if len(to_install) == 0:
            return {"changed": False, "msg": "package(s) already present"}
        if check_mode:
            return {"changed": True, "msg": "would install %d package(s)" % len(to_install)}
        for pkg in to_install:
            res = ctx.run([
                slackpkg_path, "-default_answer=y", "-batch=on", "install", pkg
            ])
            if res.rc != 0:
                fail("failed to install %s: %s" % (pkg, res.stderr))
            if not package_is_installed(pkg):
                fail("failed to install %s (not found after install)" % pkg)
        return {"changed": True, "msg": "installed %d package(s)" % len(to_install)}

    elif state == "absent":
        to_remove = []
        for pkg in pkgs:
            if package_is_installed(pkg):
                to_remove.append(pkg)
        if len(to_remove) == 0:
            return {"changed": False, "msg": "package(s) already absent"}
        if check_mode:
            return {"changed": True, "msg": "would remove %d package(s)" % len(to_remove)}
        for pkg in to_remove:
            res = ctx.run([
                slackpkg_path, "-default_answer=y", "-batch=on", "remove", pkg
            ])
            if res.rc != 0:
                fail("failed to remove %s: %s" % (pkg, res.stderr))
            if package_is_installed(pkg):
                fail("failed to remove %s (still present)" % pkg)
        return {"changed": True, "msg": "removed %d package(s)" % len(to_remove)}

    elif state == "latest":
        to_upgrade = []
        for pkg in pkgs:
            # For 'latest', we attempt upgrade even if installed
            to_upgrade.append(pkg)
        if len(to_upgrade) == 0:
            return {"changed": False, "msg": "no packages to upgrade"}
        if check_mode:
            return {"changed": True, "msg": "would upgrade %d package(s)" % len(to_upgrade)}
        for pkg in to_upgrade:
            res = ctx.run([
                slackpkg_path, "-default_answer=y", "-batch=on", "upgrade", pkg
            ])
            if res.rc != 0:
                fail("failed to upgrade %s: %s" % (pkg, res.stderr))
            if not package_is_installed(pkg):
                fail("failed to upgrade %s (not found after upgrade)" % pkg)
        return {"changed": True, "msg": "upgraded %d package(s)" % len(to_upgrade)}

    fail("unreachable state reached: %s" % state)
