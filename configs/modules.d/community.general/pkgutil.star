def main(ctx, params):
    name = params["name"]
    state = params["state"]
    site = params.get("site")
    update_catalog = params.get("update_catalog", False)
    force = params.get("force", False)

    if state in ["installed", "present"]:
        if name == ["*"]:
            fail("Can not use 'state: present' with name: '*'")

        # Check which packages are not installed
        not_installed = []
        for pkg in name:
            res = ctx.run(["/opt/csw/bin/pkginfo", "-q", pkg], mutates=False)
            if res.rc != 0:
                not_installed.append(pkg)

        if len(not_installed) == 0:
            return {"changed": False, "msg": "All specified packages are already installed"}

        # Install the missing packages
        cmd = ["pkgutil", "-iy"]
        if update_catalog:
            cmd.append("-U")
        if site != None:
            cmd.extend(["-t", site])
        if force:
            cmd.append("-f")
        cmd.extend(not_installed)
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would install packages: " + " ".join(not_installed)}
        if res.rc != 0:
            fail("Failed to install packages: " + (res.stderr if res.stderr != "" else res.stdout))

        return {"changed": True, "msg": "Installed packages: " + " ".join(not_installed)}

    elif state == "latest":
        if name == ["*"]:
            # Update catalog if requested
            if update_catalog:
                ctx.run(["pkgutil", "-U"], mutates=False)

            # Check for outdated packages (catalog check)
            cmd = ["pkgutil", "-c"]
            if site != None:
                cmd.extend(["-t", site])
            res = ctx.run(cmd, mutates=False)
            if res.rc != 0:
                fail("Failed to check package status: " + (res.stderr if res.stderr != "" else res.stdout))

            outdated = []
            for line in res.stdout.split("\n")[1:-1]:
                if "catalog" not in line and "SAME" not in line:
                    parts = line.split()
                    if len(parts) > 0:
                        outdated.append(parts[0])
            outdated = list(set(outdated))  # deduplicate

            if len(outdated) == 0:
                return {"changed": False, "msg": "All packages are already at latest version"}

            # Run upgrade without specific packages (updates all)
            cmd = ["pkgutil", "-uy"]
            if update_catalog:
                cmd.append("-U")
            if site != None:
                cmd.extend(["-t", site])
            if force:
                cmd.append("-f")
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would update all packages"}
            if res.rc != 0:
                fail("Failed to upgrade packages: " + (res.stderr if res.stderr != "" else res.stdout))

            return {"changed": True, "msg": "Upgraded all packages"}

        else:
            # Specific packages
            # First find which are not installed
            not_installed = []
            for pkg in name:
                res = ctx.run(["/opt/csw/bin/pkginfo", "-q", pkg], mutates=False)
                if res.rc != 0:
                    not_installed.append(pkg)

            # Then find which installed ones are outdated
            outdated = []
            if len(name) > 0:
                cmd = ["pkgutil", "-c"]
                if site != None:
                    cmd.extend(["-t", site])
                cmd.extend(name)
                res = ctx.run(cmd, mutates=False)
                if res.rc == 0:
                    for line in res.stdout.split("\n")[1:-1]:
                        if "catalog" not in line and "SAME" not in line:
                            parts = line.split()
                            if len(parts) > 0:
                                outdated.append(parts[0])
            outdated = list(set(outdated))

            to_update = not_installed + outdated
            # Deduplicate while preserving order
            seen = set()
            unique_to_update = []
            for pkg in to_update:
                if pkg not in seen:
                    seen.add(pkg)
                    unique_to_update.append(pkg)

            if len(unique_to_update) == 0:
                return {"changed": False, "msg": "All specified packages are already at desired state"}

            cmd = ["pkgutil", "-uy"]
            if update_catalog:
                cmd.append("-U")
            if site != None:
                cmd.extend(["-t", site])
            if force:
                cmd.append("-f")
            cmd.extend(unique_to_update)
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would upgrade packages: " + " ".join(unique_to_update)}
            if res.rc != 0:
                fail("Failed to upgrade packages: " + (res.stderr if res.stderr != "" else res.stdout))

            return {"changed": True, "msg": "Upgraded packages: " + " ".join(unique_to_update)}

    elif state in ["absent", "removed"]:
        # Find packages actually installed
        to_remove = []
        for pkg in name:
            res = ctx.run(["/opt/csw/bin/pkginfo", "-q", pkg], mutates=False)
            if res.rc == 0:
                to_remove.append(pkg)

        if len(to_remove) == 0:
            return {"changed": False, "msg": "No specified packages are installed"}

        cmd = ["pkgutil", "-ry"]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove packages: " + " ".join(to_remove)}
        if res.rc != 0:
            fail("Failed to remove packages: " + (res.stderr if res.stderr != "" else res.stdout))

        return {"changed": True, "msg": "Removed packages: " + " ".join(to_remove)}

    fail("Unsupported state: " + state)
