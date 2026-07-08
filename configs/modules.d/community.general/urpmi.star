def root_option(root):
    return "--root=%s" % root if root != None else ""

def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    force = params.get("force", True)
    no_recommends = params.get("no_recommends", True)
    root = params.get("root")
    update_cache = params.get("update_cache", False)

    if state not in ["absent", "installed", "present", "removed"]:
        fail("unsupported state: " + state)

    # Update cache if requested
    if update_cache:
        res = ctx.run(["urpmi.update", "-a", "-q"], mutates=True)
        if res.rc != 0:
            fail("could not update package database")

    # Normalize state aliases
    if state == "installed":
        state = "present"
    elif state == "removed":
        state = "absent"

    if state == "present":
        # Install logic: check if packages are installed
        packages = ""
        for pkg in name:
            res = ctx.run(["rpm", "-q", "--whatprovides", pkg] + ([root_option(root)] if root != None else []))
            if res.rc != 0:
                packages += "'" + pkg + "' "

        if packages == "":
            return {"changed": False, "msg": "all packages already present"}

        # Build install command
        args = ["urpmi", "--auto"]
        if force:
            args.append("--force")
        if no_recommends:
            args.append("--no-recommends")
        args.append("--quiet")
        if root != None:
            args.append(root_option(root))
        args.extend(packages.strip().split(" "))

        res = ctx.run(args, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would install packages"}

        if res.rc != 0:
            fail("failed to install packages: " + res.stderr)

        # Verify installation succeeded
        for pkg in name:
            res2 = ctx.run(["rpm", "-q", "--whatprovides", pkg] + ([root_option(root)] if root != None else []))
            if res2.rc != 0:
                fail("package '" + pkg + "' is not installed")

        return {"changed": True, "msg": "installed packages"}

    elif state == "absent":
        # Remove logic: count packages to remove
        remove_c = 0
        for pkg in name:
            res = ctx.run(["rpm", "-q", pkg] + ([root_option(root)] if root != None else []))
            if res.rc == 0:
                remove_c += 1

        if remove_c == 0:
            return {"changed": False, "msg": "package(s) already absent"}

        # Build removal command
        args = ["urpme", "--auto"]
        if root != None:
            args.append(root_option(root))
        args.extend(name)

        res = ctx.run(args, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove packages"}

        if res.rc != 0:
            fail("failed to remove packages: " + res.stderr)

        # Verify removal succeeded
        for pkg in name:
            res2 = ctx.run(["rpm", "-q", pkg] + ([root_option(root)] if root != None else []))
            if res2.rc == 0:
                fail("package '" + pkg + "' is still installed")

        return {"changed": True, "msg": "removed " + str(remove_c) + " package(s)"}

    fail("unsupported state: " + state)
