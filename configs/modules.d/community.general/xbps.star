def main(ctx, params):
    name = params.get("name")
    if name != None and type(name) != "list":
        fail("name must be a list of strings")
    name = name if name != None else []
    
    state = params.get("state", "present")
    if state == "installed":
        state = "present"
    elif state == "removed":
        state = "absent"
    elif state not in ["present", "absent", "latest"]:
        fail("unsupported state: %s" % state)

    recurse = params.get("recurse", False)
    update_cache = params.get("update_cache", True)
    upgrade = params.get("upgrade", False)
    upgrade_xbps = params.get("upgrade_xbps", True)

    if not (name or update_cache or upgrade):
        fail("one of name, update_cache, or upgrade is required")

    # locate xbps binaries
    xbps_install = ctx.run(["which", "xbps-install"], mutates=False)
    if xbps_install.rc != 0:
        fail("cannot find xbps-install binary")
    xbps_install_path = xbps_install.stdout.strip()
    
    xbps_query = ctx.run(["which", "xbps-query"], mutates=False)
    if xbps_query.rc != 0:
        fail("cannot find xbps-query binary")
    xbps_query_path = xbps_query.stdout.strip()

    xbps_remove = ctx.run(["which", "xbps-remove"], mutates=False)
    if xbps_remove.rc != 0:
        fail("cannot find xbps-remove binary")
    xbps_remove_path = xbps_remove.stdout.strip()

    def update_package_db():
        res = ctx.run([xbps_install_path, "-S"], mutates=True)
        if res.rc != 0:
            fail("could not update package database")
        return "avg rate" in res.stdout

    def query_package(pkg_name, want_state):
        """returns (installed, up_to_date)"""
        res = ctx.run([xbps_query_path, pkg_name], mutates=False)
        installed = res.rc == 0 and len(res.stdout.strip()) > 0
        
        if not installed or want_state != "latest":
            return installed, False

        # check if package needs upgrade by comparing with remote
        res = ctx.run([xbps_install_path, "-Sun"], mutates=False)
        remote_updates = res.stdout.strip().split("\n") if res.rc == 0 or res.rc == 17 else []
        up_to_date = pkg_name not in remote_updates
        return installed, up_to_date

    def upgrade_system():
        # check what needs upgrade first
        res = ctx.run([xbps_install_path, "-un"], mutates=False)
        if res.rc != 0:
            fail("could not check for upgrades")
        needs_upgrade = len(res.stdout.strip()) > 0
        
        if not needs_upgrade:
            if ctx.check_mode:
                return {"changed": False, "msg": "Nothing to upgrade"}
            return {"changed": False, "msg": "Nothing to upgrade"}

        if ctx.check_mode:
            return {"changed": True, "msg": "Would have performed upgrade"}

        # perform upgrade
        res = ctx.run([xbps_install_path, "-uy"], mutates=True)
        if res.rc == 0:
            return {"changed": True, "msg": "System upgraded"}
        elif res.rc == 16 and upgrade_xbps:
            # try to upgrade xbps first
            upgrade_res = ctx.run([xbps_install_path, "-uy", "xbps"], mutates=True)
            if upgrade_res.rc != 0:
                fail("could not upgrade xbps")
            # retry upgrade
            return upgrade_system()
        else:
            fail("could not perform system upgrade: " + res.stderr)

    def install_packages(pkgs):
        to_install = []
        for pkg in pkgs:
            installed, up_to_date = query_package(pkg, state)
            if installed and state in ["present", "latest"] and (state != "latest" or up_to_date):
                continue
            to_install.append(pkg)

        if len(to_install) == 0:
            return {"changed": False, "msg": "Nothing to install"}

        if ctx.check_mode:
            return {"changed": True, "msg": "Would install " + str(len(to_install)) + " package(s)", "packages": to_install}

        cmd = [xbps_install_path, "-y"] + to_install
        res = ctx.run(cmd, mutates=True)
        
        if res.rc == 16 and upgrade_xbps:
            # upgrade xbps and retry
            upgrade_res = ctx.run([xbps_install_path, "-uy", "xbps"], mutates=True)
            if upgrade_res.rc != 0:
                fail("could not upgrade xbps")
            return install_packages(to_install)
        elif res.rc != 0:
            fail("failed to install " + str(len(to_install)) + " package(s)")

        return {"changed": True, "msg": "installed " + str(len(to_install)) + " package(s)", "packages": to_install}

    def remove_packages(pkgs):
        changed_pkgs = []
        for pkg in pkgs:
            installed, _ = query_package(pkg, "absent")
            if not installed:
                continue

            if ctx.check_mode:
                changed_pkgs.append(pkg)
                continue

            cmd = [xbps_remove_path, "-y", pkg]
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("failed to remove " + pkg)
            changed_pkgs.append(pkg)

        if ctx.check_mode:
            return {"changed": True, "msg": "Would remove " + str(len(changed_pkgs)) + " package(s)", "packages": changed_pkgs}

        if len(changed_pkgs) > 0:
            return {"changed": True, "msg": "removed " + str(len(changed_pkgs)) + " package(s)", "packages": changed_pkgs}
        return {"changed": False, "msg": "package(s) already absent"}

    def check_packages(pkgs, want_state):
        would_change = []
        for pkg in pkgs:
            installed, up_to_date = query_package(pkg, want_state)
            if (want_state in ["present", "latest"] and not installed) or \
               (want_state == "absent" and installed) or \
               (want_state == "latest" and not up_to_date):
                would_change.append(pkg)

        if len(would_change) == 0:
            return {"changed": False, "msg": "package(s) already " + want_state}
        
        return {"changed": True, "msg": str(len(would_change)) + " package(s) would be " + ("removed" if want_state == "absent" else want_state), "packages": would_change}

    # update package cache if requested
    if update_cache:
        if ctx.check_mode:
            if upgrade or name:
                return {"changed": True, "msg": "Would have updated the package cache"}
            return {"changed": True, "msg": "Would have updated the package cache"}
        changed = update_package_db()
        return {"changed": changed, "msg": "Updated the package master lists" if changed else "Package list already up to date"}

    # handle system upgrade
    if upgrade:
        return upgrade_system()

    # handle package operations
    if len(name) == 0:
        return {"changed": False, "msg": "No packages specified"}

    if ctx.check_mode:
        return check_packages(name, state)

    if state in ["present", "latest"]:
        return install_packages(name)
    elif state == "absent":
        return remove_packages(name)

    fail("unhandled state: " + state)
