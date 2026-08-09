def main(ctx, params):
    name_list = params["name"]
    state = params.get("state", "present")
    pkg_type = params.get("type", "package")
    extra_args_precommand = params.get("extra_args_precommand")
    disable_gpg_check = params.get("disable_gpg_check", False)
    disable_recommends = params.get("disable_recommends", True)
    force = params.get("force", False)
    force_resolution = params.get("force_resolution", False)
    update_cache = params.get("update_cache", False)
    oldpackage = params.get("oldpackage", False)
    extra_args = params.get("extra_args")
    allow_vendor_change = params.get("allow_vendor_change", False)
    replacefiles = params.get("replacefiles", False)
    clean_deps = params.get("clean_deps", False)

    if not name_list or len(name_list) == 0:
        fail("name is required and must be a non-empty list")

    names = [n for n in name_list if n != ""]

    if state == "dist-upgrade":
        if names != ["*"]:
            fail("dist-upgrade can only be applied to '*' (all packages)")

    zypper = ctx.run(["which", "zypper"], mutates=False)
    if zypper.rc != 0:
        fail("zypper not found on system")
    zypper_path = zypper.stdout.strip()

    cmd = [zypper_path, "--quiet", "--non-interactive", "--xmlout"]

    if ctx.file_exists("/usr/sbin/transactional-update"):
        trans_cmd = ["/usr/sbin/transactional-update", "--continue", "--drop-if-no-change", "--quiet", "run"] + cmd
        cmd = trans_cmd

    if extra_args_precommand != None and len(extra_args_precommand.strip()) > 0:
        args = extra_args_precommand.strip().split()
        cmd.extend(args)

    if disable_gpg_check:
        cmd.append("--no-gpg-checks")

    if update_cache and not ctx.check_mode:
        refresh_cmd = cmd + ["refresh"]
        res = ctx.run(refresh_cmd, mutates=False)
        if res.rc != 0:
            fail("zypper refresh failed: " + res.stderr)

    is_install = state in ["present", "latest", "installed"]
    is_remove = state in ["absent", "removed"]
    is_update = state == "dist-upgrade"
    is_patch = state == "latest" and pkg_type == "patch"
    is_update_all = state == "latest" and pkg_type != "patch"

    if is_install or is_remove:
        installed_pkgs = _get_installed_packages(ctx, names)
        to_install = []
        to_remove = []

        for pkg in names:
            if "://" in pkg or pkg.endswith(".rpm"):
                if is_install:
                    to_install.append(pkg)
            else:
                prefix = ""
                pname = pkg
                version = ""
                if pkg[0] in ["-", "~", "+"]:
                    prefix = pkg[0]
                    pname = pkg[1:]
                if prefix == "~":
                    prefix = "-"

                # Extract version spec if present
                sep_found = False
                for sep in [">=", "<=", ">", "<", "="]:
                    if sep in pname:
                        idx = pname.find(sep)
                        version = pname[idx:]
                        pname = pname[:idx]
                        sep_found = True
                        break

                if is_install:
                    installed = installed_pkgs.get(pname)
                    if installed == None or len(version) > 0:
                        to_install.append(pname + version)
                elif is_remove:
                    if pname in installed_pkgs:
                        to_remove.append(pname)

        if len(to_install) == 0 and len(to_remove) == 0:
            return {"changed": False, "msg": "all specified packages already in desired state"}

        if len(to_install) > 0 and len(to_remove) > 0:
            fail("cannot install and remove packages in same command")

        if len(to_install) > 0:
            cmd.append("install")
            cmd.append("--auto-agree-with-licenses")
            if disable_recommends:
                cmd.append("--no-recommends")
            if force:
                cmd.append("--force")
            if force_resolution:
                cmd.append("--force-resolution")
            need_oldpackage = oldpackage or len(to_install) > 0
            for p in to_install:
                if "=" in p or "<" in p or ">" in p:
                    need_oldpackage = True
                    break
            if need_oldpackage:
                cmd.append("--oldpackage")
            if replacefiles:
                cmd.append("--replacefiles")
            cmd.append("--")
            cmd.extend(to_install)
        else:
            cmd.append("remove")
            if clean_deps:
                cmd.append("--clean-deps")
            cmd.extend(to_remove)
    elif is_update_all:
        cmdname = "patch" if is_patch else "update"
        cmd.append(cmdname)
    elif is_update:
        cmd.append("dist-upgrade")
        if allow_vendor_change:
            cmd.append("--allow-vendor-change")
    else:
        fail("unsupported state: " + state)

    if extra_args != None and len(extra_args.strip()) > 0:
        args = extra_args.strip().split()
        cmd.extend(args)

    if ctx.check_mode:
        cmd.append("--dry-run")

    res = ctx.run(cmd, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would run zypper command (check mode)"}
    if res.rc not in [0, 102, 106]:
        fail("zypper command failed: " + res.stderr)

    changed = len(res.stdout.strip()) > 0 or res.rc in [102]
    if not changed:
        return {"changed": False, "msg": "no changes required"}

    return {"changed": True, "msg": "zypper completed successfully"}


def _get_installed_packages(ctx, names):
    zypper = ctx.run(["which", "zypper"], mutates=False)
    if zypper.rc != 0:
        fail("zypper not found")
    zypper_path = zypper.stdout.strip()
    cmd = [zypper_path, "search", "--match-exact", "--details", "--installed-only"]
    cmd.extend(names)
    res = ctx.run(cmd, mutates=False)
    if res.rc == 104:
        return {}
    if res.rc != 0:
        fail("failed to list installed packages: " + res.stderr)

    installed = {}
    lines = res.stdout.split("\n")
    for line in lines:
        if "name=" in line and "status=" in line and "edition=" in line:
            parts = line.split('"')
            name = None
            edition = None
            for i in range(len(parts)):
                if i > 0 and parts[i - 1].strip() == "name":
                    name = parts[i]
                if i > 0 and parts[i - 1].strip() == "edition":
                    edition = parts[i]
            if name != None and edition != None:
                installed[name] = edition
    return installed
