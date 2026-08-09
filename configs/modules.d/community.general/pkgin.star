def main(ctx, params):
    # Map parameters
    state = params.get("state", "present")
    pkgs = params.get("name")
    update_cache = params.get("update_cache", False)
    upgrade = params.get("upgrade", False)
    full_upgrade = params.get("full_upgrade", False)
    clean = params.get("clean", False)
    force = params.get("force", False)

    # Validate at least one operation is requested
    if not (pkgs or update_cache or upgrade or full_upgrade or clean):
        fail("one of name, update_cache, upgrade, full_upgrade, or clean is required")

    # Determine pkgin path
    res = ctx.run(["which", "pkgin"], ok_codes=[0, 1])
    if res.rc != 0:
        fail("pkgin not found in PATH")
    pkgin_path = res.stdout.strip()

    # Helper: build pkgin command
    def build_cmd(cmd, package=None):
        force_flag = "-F" if force else ""
        package_arg = package if package else ""
        if ctx.check_mode:
            return [pkgin_path, "-n", cmd, package_arg]
        else:
            return [pkgin_path, "-y", force_flag, cmd, package_arg]

    # Helper: query package state
    def query_package(name):
        # Try -p flag first (parsable)
        res = ctx.run([pkgin_path, "-p", "-v"], ok_codes=[0, 1])
        if res.rc == 0:
            pflag = "-p"
            splitchar = ";"
        else:
            pflag = ""
            splitchar = " "

        # Search for exact package name
        res = ctx.run([pkgin_path, pflag, "search", "^" + name + "$"])
        if res.rc != 0:
            return "not_found"

        lines = res.stdout.strip().split("\n")
        for line in lines:
            if not line.strip():
                continue
            parts = line.split(splitchar)
            if len(parts) < 2:
                continue
            pkg_with_ver = parts[0].strip()
            raw_state = parts[1].strip() if len(parts) > 1 else ""

            # Strip version to compare name
            idx = pkg_with_ver.rfind("-")
            if idx != -1:
                pkg_base = pkg_with_ver[:idx]
            else:
                pkg_base = pkg_with_ver

            if pkg_with_ver != name and pkg_base != name:
                continue

            if raw_state == "<":
                return "outdated"
            elif raw_state == "=" or raw_state == ">":
                return "present"
            else:
                return "not_installed"

        return "not_found"

    # Helper: update cache
    if update_cache:
        res = ctx.run(build_cmd("update"))
        if res.rc != 0:
            fail("failed to update package db: " + res.stderr)
        # Check if database was actually updated
        if "is up-to-date" in res.stdout or res.stdout.strip().endswith("is up-to-date"):
            changed = False
            msg = "database is up-to-date"
        else:
            changed = True
            msg = "updated repository database"

        # Return early if only updating cache
        if not (pkgs or upgrade or full_upgrade or clean):
            return {"changed": changed, "msg": msg}

    # Helper: upgrade
    if upgrade:
        res = ctx.run(build_cmd("upgrade"))
        if res.rc != 0:
            fail("failed to upgrade packages: " + res.stderr)
        if "nothing to do" in res.stdout.lower():
            changed = False
            msg = "nothing left to upgrade"
        else:
            changed = True
            msg = "upgraded packages"
        if not pkgs:
            return {"changed": changed, "msg": msg}

    # Helper: full-upgrade
    if full_upgrade:
        res = ctx.run(build_cmd("full-upgrade"))
        if res.rc != 0:
            fail("failed to full-upgrade packages: " + res.stderr)
        if "nothing to do" in res.stdout.lower():
            changed = False
            msg = "nothing left to upgrade"
        else:
            changed = True
            msg = "upgraded all packages"
        if not pkgs:
            return {"changed": changed, "msg": msg}

    # Helper: clean cache
    if clean:
        res = ctx.run(build_cmd("clean"))
        if res.rc != 0:
            fail("failed to clean package cache: " + res.stderr)
        changed = True
        msg = "cleaned caches"
        if not pkgs:
            return {"changed": changed, "msg": msg}

    # Handle package operations if name specified
    if pkgs == None:
        fail("name is required for install/remove operations")

    if state not in ("present", "absent"):
        fail("unsupported state: " + state + " (must be 'present' or 'absent')")

    # Normalize to list
    if isinstance(pkgs, str):
        pkg_list = [p.strip() for p in pkgs.split(",") if p.strip()]
    elif type(pkgs) == "list":
        pkg_list = []
        for p in pkgs:
            if type(p) == "string":
                pkg_list.append(p)
            else:
                fail("name items must be strings; got " + str(type(p)))
    else:
        fail("name must be a string or list of strings")

    if not pkg_list:
        fail("no packages specified")

    changed = False
    count = 0

    if state == "present":
        for pkg in pkg_list:
            q = query_package(pkg)
            if q in ("present", "outdated"):
                continue
            if q == "not_found":
                fail("failed to find package " + pkg + " for installation")
            # install
            res = ctx.run(build_cmd("install", pkg))
            if res.rc != 0:
                fail("failed to install " + pkg + ": " + res.stderr)
            # verify
            if not ctx.check_mode:
                q2 = query_package(pkg)
                if q2 not in ("present", "outdated"):
                    fail("failed to install " + pkg)
            changed = True
            count += 1

        if changed:
            msg = "installed %d package%s" % (count, "s" if count != 1 else "")
        else:
            msg = "package(s) already present"

    elif state == "absent":
        for pkg in pkg_list:
            q = query_package(pkg)
            if q in ("not_installed", "not_found"):
                continue
            # remove
            res = ctx.run(build_cmd("remove", pkg))
            if res.rc != 0:
                fail("failed to remove " + pkg + ": " + res.stderr)
            # verify
            if not ctx.check_mode:
                q2 = query_package(pkg)
                if q2 in ("present", "outdated"):
                    fail("failed to remove " + pkg)
            changed = True
            count += 1

        if changed:
            msg = "removed %d package%s" % (count, "s" if count != 1 else "")
        else:
            msg = "package(s) already absent"

    return {"changed": changed, "msg": msg}
