def main(ctx, params):
    packages = []
    package_list = params["name"]

    # Merge split FRMIs (IPS uses comma before release number)
    for fragment in package_list:
        is_version_start = False
        # Check if fragment starts with digits (possibly with dots)
        if len(fragment) > 0 and fragment[0] >= '0' and fragment[0] <= '9':
            is_version_start = True
            for c in fragment:
                if c != '.' and (c < '0' or c > '9'):
                    is_version_start = False
                    break

        if is_version_start:
            if len(packages) > 0 and packages[-1].find("@") != -1 and packages[-1].endswith(","):
                packages[-1] += fragment
            else:
                packages.append(fragment)
        else:
            packages.append(fragment)

    state = params.get("state", "present")
    if state == "present" or state == "installed":
        operation = "present"
    elif state == "latest":
        operation = "latest"
    elif state == "absent" or state == "removed" or state == "uninstalled":
        operation = "absent"
    else:
        fail("unsupported state: " + state)

    accept_licenses = [] if not params.get("accept_licenses", False) else ["--accept"]
    be_name = params.get("be_name")
    beadm = ["--be-name=" + be_name] if be_name != None else []
    no_refresh = [] if params.get("refresh", True) else ["--no-refresh"]

    to_modify = []
    for pkg in packages:
        if operation == "absent":
            if _is_installed(ctx, pkg):
                to_modify.append(pkg)
        elif operation == "present":
            if not _is_installed(ctx, pkg):
                to_modify.append(pkg)
        elif operation == "latest":
            if not _is_installed(ctx, pkg) or not _is_latest(ctx, pkg):
                to_modify.append(pkg)

    if len(to_modify) > 0:
        subcommand = "install" if operation != "absent" else "uninstall"
        cmd = ["pkg", subcommand] + accept_licenses + beadm + no_refresh + ["-q", "--"] + to_modify

        if ctx.check_mode:
            # In check_mode, simulate without running
            return {"changed": True, "msg": "would " + subcommand + " " + ", ".join(to_modify)}

        res = ctx.run(cmd)
        if res.rc == 4:
            # pkg5 returns rc=4 for no changes needed
            return {"changed": False, "msg": ""}
        if res.rc != 0:
            fail("pkg5 " + subcommand + " failed: " + res.stderr)

        return {"changed": True, "msg": ""}

    return {"changed": False, "msg": ""}


def _is_installed(ctx, package):
    res = ctx.run(["pkg", "list", "--", package])
    return res.rc == 0


def _is_latest(ctx, package):
    res = ctx.run(["pkg", "list", "-u", "--", package])
    return res.rc != 0
