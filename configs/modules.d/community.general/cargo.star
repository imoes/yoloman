def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    version = params.get("version")
    path = params.get("path")
    locked = params.get("locked", False)
    executable = params.get("executable")

    # Determine cargo executable path
    if executable:
        cargo = [executable]
    else:
        # Fallback: assume 'cargo' is in PATH; ctx.run will fail if not found
        cargo = ["cargo"]

    # Get installed packages
    res = ctx.run(cargo + ["install", "--list"], mutates=False)
    installed = {}
    if res.rc == 0:
        for line in res.stdout.splitlines():
            match = line.strip().split()
            if len(match) >= 2 and match[0].endswith('v'):
                pkg_name = match[0][:-1]  # remove trailing 'v'
                pkg_version = match[1].rstrip(':')
                installed[pkg_name] = pkg_version

    changed = False
    msg = ""
    out = ""
    err = ""

    if state == "present":
        to_install = []
        for pkg in name:
            if pkg not in installed:
                to_install.append(pkg)
            elif version and version != installed[pkg]:
                to_install.append(pkg)

        if to_install:
            changed = True
            cmd = cargo + ["install"] + to_install
            if locked:
                cmd.append("--locked")
            if path:
                cmd.extend(["--root", path])
            if version:
                cmd.extend(["--version", version])

            if ctx.check_mode:
                return {
                    "changed": True,
                    "msg": "would install package(s): " + ", ".join(to_install)
                }
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("failed to install package(s): " + res.stderr)
            out = res.stdout
            err = res.stderr
            msg = "installed " + ", ".join(to_install)

    elif state == "latest":
        to_update = []
        for pkg in name:
            if pkg not in installed:
                to_update.append(pkg)
            else:
                # Fetch latest version from cargo search (read-only probe)
                res_search = ctx.run(cargo + ["search", pkg, "--limit", "1"], mutates=False)
                if res_search.rc == 0:
                    # Extract version from output: e.g., 'ludusavi v0.12.0 (registry+https://github.com/rust-lang/crates.io-index)'
                    match = res_search.stdout.strip().split()
                    if len(match) >= 2:
                        latest_ver = match[1].split('v')[1].split()[0] if 'v' in match[1] else None
                        if latest_ver and installed[pkg] != latest_ver:
                            to_update.append(pkg)
                    else:
                        # If search fails or output is malformed, assume outdated
                        to_update.append(pkg)
                else:
                    # If search fails, assume outdated
                    to_update.append(pkg)

        if to_update:
            changed = True
            cmd = cargo + ["install"] + to_update
            if locked:
                cmd.append("--locked")
            if path:
                cmd.extend(["--root", path])
            if version:
                cmd.extend(["--version", version])

            if ctx.check_mode:
                return {
                    "changed": True,
                    "msg": "would update package(s): " + ", ".join(to_update)
                }
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("failed to update package(s): " + res.stderr)
            out = res.stdout
            err = res.stderr
            msg = "updated " + ", ".join(to_update)

    elif state == "absent":
        to_uninstall = [pkg for pkg in name if pkg in installed]
        if to_uninstall:
            changed = True
            cmd = cargo + ["uninstall"] + to_uninstall

            if ctx.check_mode:
                return {
                    "changed": True,
                    "msg": "would uninstall package(s): " + ", ".join(to_uninstall)
                }
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("failed to uninstall package(s): " + res.stderr)
            out = res.stdout
            err = res.stderr
            msg = "uninstalled " + ", ".join(to_uninstall)

    else:
        fail("unsupported state: " + state)

    return {"changed": changed, "msg": msg, "stdout": out, "stderr": err}
