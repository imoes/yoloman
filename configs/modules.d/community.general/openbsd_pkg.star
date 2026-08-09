def main(ctx, params):
    # Map Ansible state choices to canonical forms
    state_map = {
        "installed": "present",
        "removed": "absent",
    }
    state = state_map.get(params["state"], params["state"])
    names = params["name"]
    build = params.get("build", False)
    snapshot = params.get("snapshot", False)
    quick = params.get("quick", False)
    clean = params.get("clean", False)
    ports_dir = params.get("ports_dir", "/usr/ports")

    # Validation: mutually exclusive build/snapshot
    if build and snapshot:
        fail("build and snapshot are mutually exclusive")

    # '*' handling: only valid alone and with state=latest
    asterisk = "*" in names
    if asterisk:
        if len(names) != 1:
            fail("the package name '*' can not be mixed with other names")
        if state != "latest":
            fail("the package name '*' is only valid when using state=latest")

    # Check mode and actual state
    if asterisk:
        # pkg_add -Imu (or with flags)
        cmd = ["pkg_add", "-Imu"]
        if snapshot:
            cmd.append("-Dsnap")
        if clean:
            cmd.append("c")
        if quick:
            cmd.append("q")
        if ctx.check_mode:
            cmd.append("n")
        res = ctx.run(cmd)
        # Detect change by version string in output like "foo-1.0->2.0: ok"
        changed = ": ok" in res.stdout and "->" in res.stdout
        return {"changed": changed, "msg": "would upgrade all packages" if ctx.check_mode else "upgraded all packages"}

    # Parse package name components: stem, version, flavor, branch
    pkg_spec = {}
    for name in names:
        stem = name
        version = None
        flavor = None
        branch = None

        # Detect style: version, versionless (--), or stem-only
        if "--" in name:
            # versionless
            idx = name.find("--")
            stem = name[:idx]
            rest = name[idx+2:]
            if "%" in rest:
                idx2 = rest.find("%")
                flavor = rest[:idx2]
                branch = rest[idx2+1:]
            else:
                flavor = rest
        elif name.count("-") >= 2 and name.rsplit("-", 1)[1][0].isdigit():
            # has version
            idx = name.rfind("-")
            stem = name[:idx]
            rest = name[idx+1:]
            # branch?
            if "%" in rest:
                idx2 = rest.find("%")
                version = rest[:idx2]
                branch = rest[idx2+1:]
            else:
                version = rest
        elif "%" in name:
            idx = name.find("%")
            stem = name[:idx]
            branch = name[idx+1:]

        pkg_spec[name] = {
            "stem": stem,
            "version": version,
            "flavor": flavor,
            "branch": branch,
        }

    # Check if sqlports needs to be installed (only for build)
    if build:
        res = ctx.run(["pkg_info", "-Iq", "inst:sqlports"])
        if res.rc != 0:
            # install sqlports
            cmd = ["pkg_add", "-Im", "sqlports"]
            if snapshot:
                cmd.append("-Dsnap")
            res = ctx.run(cmd)
            if res.rc != 0:
                fail("failed to install sqlports: " + res.stderr)

    # Check installed state for each package
    installed_names = {}  # {name: [list of installed names]}
    for name in names:
        pkg = pkg_spec[name]
        stem = pkg["stem"]
        # Try to find exact match or stem match via pkg_info -Iq
        res = ctx.run(["pkg_info", "-Iq", "inst:" + name])
        if res.rc == 0:
            # Could be multiple matches (e.g., just stem)
            installed_names[name] = res.stdout.splitlines()
        else:
            # Try stem-only fallback if name was not exact
            res2 = ctx.run(["pkg_info", "-Iq", "inst:" + stem])
            if res2.rc == 0:
                installed_names[name] = res2.stdout.splitlines()
            else:
                installed_names[name] = []

    # State logic
    if state == "present":
        changed = False
        for name in names:
            pkg = pkg_spec[name]
            stem = pkg["stem"]
            installed = len(installed_names[name]) > 0

            if installed:
                # Already installed — idempotent
                continue

            # Need to install
            if ctx.check_mode:
                changed = True
                continue

            # Build or binary?
            if build:
                port_dir = ports_dir + "/" + pkg["stem"]
                if not ctx.file_exists(port_dir):
                    fail("the port source directory " + port_dir + " does not exist")
                # Build command (simplified — no subpackage/flavor handling)
                flavor = pkg["flavor"]
                if flavor:
                    flavors = flavor.replace("-", " ")
                    build_cmd = "cd " + port_dir + " && make clean=depends && FLAVOR=\"" + flavors + "\" make install && make clean=depends"
                else:
                    build_cmd = "cd " + port_dir + " && make install && make clean=depends"
                res = ctx.run(["sh", "-c", build_cmd])
            else:
                cmd = ["pkg_add", "-Im", name]
                if snapshot:
                    cmd.append("-Dsnap")
                res = ctx.run(cmd)

            if res.rc != 0:
                fail("failed to install " + name + ": " + res.stderr)
            changed = True
        return {"changed": changed, "msg": "would install packages" if ctx.check_mode else "installed packages"}

    elif state == "absent":
        changed = False
        for name in names:
            installed = len(installed_names[name]) > 0
            if not installed:
                continue

            if ctx.check_mode:
                changed = True
                continue

            cmd = ["pkg_delete", "-I", name]
            if clean:
                cmd.append("c")
            if quick:
                cmd.append("q")
            res = ctx.run(cmd)
            if res.rc != 0:
                fail("failed to remove " + name + ": " + res.stderr)
            changed = True
        return {"changed": changed, "msg": "would remove packages" if ctx.check_mode else "removed packages"}

    elif state == "latest":
        changed = False
        leftovers = []
        # First pass: attempt upgrade of installed packages
        for name in names:
            pkg = pkg_spec[name]
            stem = pkg["stem"]
            installed = len(installed_names[name]) > 0
            if not installed:
                leftovers.append(name)
                continue

            if ctx.check_mode:
                changed = True
                continue

            cmd = ["pkg_add", "-um", name]
            if snapshot:
                cmd.append("-Dsnap")
            if clean:
                cmd.append("c")
            if quick:
                cmd.append("q")
            res = ctx.run(cmd)

            if res.rc != 0:
                fail("failed to upgrade " + name + ": " + res.stderr)

            # Check output for "old->new: ok"
            found_change = False
            for inst_name in installed_names[name]:
                # Simple substring check: look for "inst_name->"
                if inst_name + "->" in res.stdout:
                    found_change = True
                    break
            if found_change:
                changed = True

        # Handle leftovers (non-installed packages) via present logic
        if leftovers:
            # Re-check installed state for leftovers
            for name in leftovers:
                res = ctx.run(["pkg_info", "-Iq", "inst:" + name])
                if res.rc != 0:
                    res2 = ctx.run(["pkg_info", "-Iq", "inst:" + pkg_spec[name]["stem"]])
                    installed_names[name] = res2.stdout.splitlines() if res2.rc == 0 else []
                else:
                    installed_names[name] = res.stdout.splitlines()
            # Reuse present logic for leftovers
            for name in leftovers:
                installed = len(installed_names[name]) > 0
                if installed:
                    continue
                if ctx.check_mode:
                    changed = True
                    continue
                if build:
                    port_dir = ports_dir + "/" + pkg_spec[name]["stem"]
                    if not ctx.file_exists(port_dir):
                        fail("the port source directory " + port_dir + " does not exist")
                    build_cmd = "cd " + port_dir + " && make install && make clean=depends"
                    res = ctx.run(["sh", "-c", build_cmd])
                else:
                    cmd = ["pkg_add", "-Im", name]
                    if snapshot:
                        cmd.append("-Dsnap")
                    res = ctx.run(cmd)
                if res.rc != 0:
                    fail("failed to install " + name + ": " + res.stderr)
                changed = True

        return {"changed": changed, "msg": "would update packages" if ctx.check_mode else "updated packages"}

    fail("unsupported state: " + state)
