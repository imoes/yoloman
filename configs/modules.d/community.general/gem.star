def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    gem_source = params.get("gem_source")
    version = params.get("version")
    include_dependencies = params.get("include_dependencies", True)
    repository = params.get("repository")
    user_install = params.get("user_install", True)
    install_dir = params.get("install_dir")
    bindir = params.get("bindir")
    norc = params.get("norc", True)
    pre_release = params.get("pre_release", False)
    include_doc = params.get("include_doc", False)
    env_shebang = params.get("env_shebang", False)
    build_flags = params.get("build_flags")
    force = params.get("force", False)
    executable = params.get("executable")

    # Validation
    if state == "latest" and version != None:
        fail("Cannot specify version when state=latest")
    if state == "latest" and gem_source != None:
        fail("Cannot maintain state=latest when installing from local source")
    if user_install and install_dir != None:
        fail("install_dir requires user_install=false")

    # Determine gem_source fallback
    if gem_source == None:
        gem_source = name

    # Build gem command
    gem_cmd = []
    if executable != None:
        gem_cmd = executable.split(" ")
    else:
        which_res = ctx.run(["which", "gem"], ok_codes=[0, 1])
        if which_res.rc != 0:
            fail("gem executable not found")
        gem_cmd = [which_res.stdout.strip()]

    # Get RubyGems version (only once)
    ver = None
    version_res = ctx.run(gem_cmd + ["--version"], ok_codes=[0])
    if version_res.rc == 0:
        lines = version_res.stdout.split("\n")
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("3.") or stripped.startswith("2.") or stripped.startswith("1."):
                parts = stripped.split(".")
                if len(parts) >= 3:
                    major = int(parts[0])
                    minor = int(parts[1])
                    patch = int(parts[2])
                    ver = (major, minor, patch)
                break

    # Build common options
    common_opts = []
    if norc and ver != None and ver >= (2, 5, 2):
        common_opts.append("--norc")

    # Build environment
    environ = None
    if install_dir != None:
        environ = {"GEM_HOME": install_dir}

    # Helper: get installed versions
    def get_installed_versions(remote=False):
        cmd = gem_cmd + ["query"] + common_opts
        if remote:
            cmd.append("--remote")
            if repository != None:
                cmd.extend(["--source", repository])
        cmd.extend(["-n", "^" + name + "$"])
        res = ctx.run(cmd, ok_codes=[0, 1], environ_update=environ)
        installed_versions = []
        if res.rc == 0:
            for line in res.stdout.splitlines():
                if "(" in line:
                    idx = line.find("(")
                    versions_str = line[idx+1:].rstrip(")")
                    for v in versions_str.split(", "):
                        installed_versions.append(v.split()[0])
        return installed_versions

    # Determine current installed state
    def gem_exists():
        if state == "latest":
            remoteversions = get_installed_versions(remote=True)
            if len(remoteversions) > 0:
                params["version"] = remoteversions[0]
        installed_versions = get_installed_versions()
        if version != None:
            return version in installed_versions
        else:
            return len(installed_versions) > 0

    # Install function
    def install_gem():
        cmd = gem_cmd + ["install"] + common_opts
        if version != None:
            cmd.extend(["--version", version])
        if repository != None:
            cmd.extend(["--source", repository])
        if include_dependencies:
            if ver != None and ver < (2, 0, 0):
                cmd.append("--include-dependencies")
        else:
            cmd.append("--ignore-dependencies")
        if user_install:
            cmd.append("--user-install")
        else:
            cmd.append("--no-user-install")
        if install_dir != None:
            cmd.extend(["--install-dir", install_dir])
        if bindir != None:
            cmd.extend(["--bindir", bindir])
        if pre_release:
            cmd.append("--pre")
        if not include_doc:
            if ver != None and ver < (2, 0, 0):
                cmd.extend(["--no-rdoc", "--no-ri"])
            else:
                cmd.append("--no-document")
        if env_shebang:
            cmd.append("--env-shebang")
        cmd.append(gem_source)
        if build_flags != None:
            cmd.extend(["--", build_flags])
        if force:
            cmd.append("--force")
        ctx.run(cmd, mutates=True, environ_update=environ)

    # Uninstall function
    def uninstall_gem():
        cmd = gem_cmd + ["uninstall"] + common_opts
        if install_dir != None:
            cmd.extend(["--install-dir", install_dir])
        if bindir != None:
            cmd.extend(["--bindir", bindir])
        if version != None:
            cmd.extend(["--version", version])
        else:
            cmd.append("--all")
        cmd.append("--executable")
        if force:
            cmd.append("--force")
        cmd.append(name)
        ctx.run(cmd, mutates=True, environ_update=environ)

    # Check mode handling
    if ctx.check_mode:
        already_installed = gem_exists()
        if state == "absent":
            changed = not already_installed
        else:  # present or latest
            changed = not already_installed
        return {
            "changed": changed,
            "msg": ("would install" if state != "absent" else "would uninstall") + " " + name + (" version " + version if version != None else "")
        }

    # Main logic
    changed = False
    if state in ["present", "latest"]:
        if not gem_exists():
            install_gem()
            changed = True
    elif state == "absent":
        if gem_exists():
            uninstall_gem()
            changed = True

    msg = ""
    if state == "absent":
        msg = "uninstalled " + name
    elif state in ["present", "latest"]:
        msg = "installed " + name
        if version != None:
            msg += " version " + version

    return {
        "changed": changed,
        "msg": msg,
        "data": {"name": name, "state": state}
    }
