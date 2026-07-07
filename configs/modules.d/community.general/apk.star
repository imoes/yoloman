def main(ctx, params):
    name = params.get("name")
    state = params.get("state", "present")
    available = params.get("available", False)
    no_cache = params.get("no_cache", False)
    repository = params.get("repository")
    update_cache = params.get("update_cache", False)
    upgrade = params.get("upgrade", False)
    world = params.get("world", "/etc/apk/world")

    # Normalize state aliases
    if state in ["present", "installed"]:
        state = "present"
    if state in ["absent", "removed"]:
        state = "absent"

    # Build apk command base
    apk = ["apk"]
    if no_cache:
        apk.append("--no-cache")
    if repository:
        for repo in repository:
            apk.extend(["--repository", repo, "--repositories-file", "/dev/null"])
    apk_path = " ".join(apk)

    # Helper to run apk commands
    def run_apk(args, mutates=False):
        full_args = apk.split() + args
        return ctx.run(full_args, mutates=mutates)

    # Check if package is installed
    def is_installed(pkg):
        res = ctx.run([apk.split()[0], "-v", "info", "--installed", pkg], mutates=False)
        return res.rc == 0

    # Check if package is at latest version
    def is_latest(pkg):
        res = ctx.run([apk.split()[0], "version", pkg], mutates=False)
        if res.rc != 0:
            return True
        lines = res.stdout.split("\n")
        for line in lines:
            if line.startswith(pkg + "-") and " < " in line:
                return False
        return True

    # Check if package is in world file (top-level)
    def is_in_world(pkg):
        content = ctx.file_read(world).split()
        for entry in content:
            if entry == pkg or entry.startswith(pkg + "@") or entry.startswith(pkg + "=") or entry.startswith(pkg + "<") or entry.startswith(pkg + ">") or entry.startswith(pkg + "~"):
                return True
        return False

    # Parse packages from apk output
    def parse_packages(stdout):
        pkgs = []
        for line in stdout.split("\n"):
            parts = line.split()
            if len(parts) >= 3 and parts[0].startswith("(") and parts[1] == "Upgrading":
                pkgs.append(parts[2])
            elif len(parts) >= 3 and parts[0].startswith("(") and parts[1] == "Installing":
                pkgs.append(parts[2])
            elif len(parts) >= 3 and parts[0].startswith("(") and parts[1] == "Removing":
                pkgs.append(parts[2])
            elif len(parts) >= 4 and parts[1].endswith(")") and parts[2] == "Upgrading":
                pkgs.append(parts[3])
        return pkgs

    # Update package cache
    if update_cache:
        res = ctx.run([apk.split()[0], "update"], mutates=False)
        if res.rc != 0:
            fail("failed to update package cache: " + res.stderr)
        if not name and not upgrade:
            return {"changed": True, "msg": "updated repository indexes"}

    # Handle upgrade
    if upgrade:
        args = ["upgrade"]
        if available:
            args.insert(0, "--available")
        res = ctx.run([apk.split()[0]] + args, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would upgrade packages"}
        if res.rc != 0:
            fail("failed to upgrade packages: " + res.stderr)
        changed_pkgs = parse_packages(res.stdout)
        if res.stdout.strip() == "OK":
            return {"changed": False, "msg": "packages already upgraded", "data": {"packages": changed_pkgs}}
        return {"changed": True, "msg": "upgraded packages", "data": {"packages": changed_pkgs}}

    # Handle package installation/removal
    if name:
        # Convert to list if string
        if isinstance(name, str):
            pkgs = [n.strip() for n in name.split(",")]
        else:
            pkgs = name
        
        to_install = []
        to_upgrade = []

        for pkg in pkgs:
            if is_installed(pkg):
                if state == "latest" and not is_latest(pkg):
                    to_upgrade.append(pkg)
            else:
                to_install.append(pkg)

        if not to_install and not to_upgrade:
            return {"changed": False, "msg": "package(s) already installed"}

        # Install/upgrade command
        if to_upgrade:
            args = ["add", "--upgrade"]
        else:
            args = ["add"]
        args.extend(to_install + to_upgrade)

        res = ctx.run([apk.split()[0]] + args, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would install/upgrade package(s)"}
        if res.rc != 0:
            fail("failed to install package(s): " + res.stderr)

        changed_pkgs = parse_packages(res.stdout)
        return {"changed": True, "msg": "installed package(s)", "data": {"packages": changed_pkgs}}

    # If no name and no upgrade, ensure update_cache was set (required_one_of)
    if not update_cache:
        fail("one of the following is required: name, update_cache, upgrade")

    return {"changed": False, "msg": "no action required"}
