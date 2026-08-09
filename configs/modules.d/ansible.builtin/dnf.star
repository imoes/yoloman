def main(ctx, params):
    # Map boolean string options to bools (Starlark lacks implicit bool conversion from strings)
    def _bool_or_none(key):
        val = params.get(key)
        if val == None:
            return None
        return True if val == True or val == "yes" or val == "1" or val == "true" else False

    # Collect package names (name or pkg alias)
    name_list = params.get("name", [])
    if type(name_list) == "string":
        # Convert comma-separated string to list
        name_list = [p.strip() for p in name_list.split(",") if p.strip()]
    elif type(name_list) != "list":
        fail("name must be a list or comma-separated string")

    # Map state to dnf subcommand
    state = params.get("state", "present")
    if state == None:
        state = "present"

    # Handle list mode (non-idempotent)
    list_cmd = params.get("list")
    if list_cmd != None:
        # dnf list installed | available | updates | repos | <pattern>
        # We map 'updates' to 'upgrades' for compatibility
        if list_cmd == "updates":
            list_cmd = "upgrades"
        res = ctx.run(["dnf", "-q", "list", list_cmd], ok_codes=[0, 1])
        # DNF returns 1 if nothing matches; treat as success with empty output
        output = res.stdout.strip() if res.stdout else ""
        return {"changed": False, "msg": "", "data": {"results": output.split("\n") if output else []}}

    # Ensure dnf exists
    res = ctx.run(["which", "dnf"])
    if res.rc != 0:
        fail("dnf command not found on system")

    # Build base dnf command
    dnf_args = ["dnf", "-y"]

    # installroot
    installroot = params.get("installroot", "/")
    if installroot:
        dnf_args.extend(["--installroot", installroot])

    # releasever
    releasever = params.get("releasever")
    if releasever:
        dnf_args.extend(["--releasever", releasever])

    # disable_gpg_check
    if _bool_or_none("disable_gpg_check"):
        dnf_args.append("--nogpgcheck")

    # sslverify
    sslverify = params.get("sslverify")
    if sslverify == False or sslverify == "no" or sslverify == "0" or sslverify == "false":
        dnf_args.append("--setopt=sslverify=False")

    # conf_file
    conf_file = params.get("conf_file")
    if conf_file:
        dnf_args.extend(["--config", conf_file])

    # cacheonly
    if _bool_or_none("cacheonly"):
        dnf_args.append("--cacheonly")

    # skip_broken
    if _bool_or_none("skip_broken"):
        dnf_args.append("--skip-broken")

    # nobest
    if _bool_or_none("nobest"):
        dnf_args.append("--setopt=best=False")

    # allow_downgrade — note: not directly supported; handled by logic below
    allow_downgrade = _bool_or_none("allow_downgrade")

    # download_only
    if _bool_or_none("download_only"):
        dnf_args.append("--downloadonly")
        download_dir = params.get("download_dir")
        if download_dir:
            dnf_args.extend(["--destdir", download_dir])

    # autoremove
    if _bool_or_none("autoremove"):
        dnf_args.append("--setopt=clean_requirements_on_remove=True")
    else:
        dnf_args.append("--setopt=clean_requirements_on_remove=False")

    # install_weak_deps
    if _bool_or_none("install_weak_deps") == False:
        dnf_args.append("--setopt=install_weak_deps=False")

    # disablerepo / enablerepo
    disablerepo = params.get("disablerepo", [])
    if type(disablerepo) == "string":
        disablerepo = [r.strip() for r in disablerepo.split(",") if r.strip()]
    for repo in disablerepo:
        dnf_args.extend(["--disablerepo", repo])

    enablerepo = params.get("enablerepo", [])
    if type(enablerepo) == "string":
        enablerepo = [r.strip() for r in enablerepo.split(",") if r.strip()]
    for repo in enablerepo:
        dnf_args.extend(["--enablerepo", repo])

    # exclude
    exclude = params.get("exclude", [])
    if type(exclude) == "string":
        exclude = [e.strip() for e in exclude.split(",") if e.strip()]
    for exc in exclude:
        dnf_args.extend(["--exclude", exc])

    # disable_excludes
    disable_excludes = params.get("disable_excludes")
    if disable_excludes:
        dnf_args.extend(["--disableexcludes", disable_excludes])

    # security / bugfix filters (DNF supports these only in update operations)
    if state == "latest":
        if _bool_or_none("security"):
            dnf_args.append("--advisory=security")
        if _bool_or_none("bugfix"):
            dnf_args.append("--advisory=bugfix")

    # Handle autoremove alone
    if (not name_list) and _bool_or_none("autoremove"):
        dnf_args.append("autoremove")
        res = ctx.run(dnf_args, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would autoremove packages"}
        if res.rc != 0:
            fail("autoremove failed: " + res.stderr)
        return {"changed": True, "msg": "autoremove completed"}

    # Parse package list and determine intent
    pkg_specs = []
    for pkg in name_list:
        # Strip whitespace
        p = pkg.strip()
        if p:
            pkg_specs.append(p)

    # Determine command
    cmd = []
    if state in ["present", "installed"]:
        cmd = ["install"]
    elif state in ["absent", "removed"]:
        cmd = ["remove"]
    elif state == "latest":
        cmd = ["upgrade"]
    else:
        fail("unsupported state: " + state)

    # Handle all wildcard for upgrade
    if state == "latest" and pkg_specs == ["*"]:
        cmd_full = dnf_args + cmd
        res = ctx.run(cmd_full, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would upgrade all packages"}
        if res.rc != 0:
            fail("upgrade all failed: " + res.stderr)
        return {"changed": True, "msg": "upgraded all packages"}

    # If no packages provided but not autoremove and not list, fail
    if not pkg_specs:
        if state in ["present", "installed", "latest"]:
            fail("no packages specified for install/update")
        elif state == "absent":
            fail("no packages specified for removal")

    # Handle latest with update_only logic
    # (DNF does not have direct update_only; simulate by checking installed status first)
    if state == "latest" and params.get("update_only", False):
        # Check installed status to filter
        to_install = []
        for spec in pkg_specs:
            # Probe installed status via 'dnf list installed' (simple check)
            probe = ctx.run(["dnf", "-q", "list", "installed", spec], ok_codes=[0, 1])
            if probe.rc == 0 and probe.stdout.strip() and spec in probe.stdout:
                to_install.append(spec)
        # If nothing installed, nothing to do
        if not to_install:
            return {"changed": False, "msg": "no installed packages match update_only pattern"}
        pkg_specs = to_install

    # Build final dnf command
    dnf_args.extend(cmd)
    dnf_args.extend(pkg_specs)

    res = ctx.run(dnf_args, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would " + cmd[0] + " packages: " + " ".join(pkg_specs)}

    if res.rc != 0:
        fail(cmd[0] + " failed: " + res.stderr)

    return {"changed": True, "msg": cmd[0] + " completed: " + " ".join(pkg_specs)}
