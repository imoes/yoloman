def main(ctx, params):
    executable = params.get("executable", "cpanm")
    from_path = params.get("from_path")
    installdeps = params.get("installdeps", False)
    locallib = params.get("locallib")
    mirror = params.get("mirror")
    mirror_only = params.get("mirror_only", False)
    mode = params.get("mode")
    name = params.get("name")
    name_check = params.get("name_check")
    notest = params.get("notest", False)
    version = params.get("version")

    # Default mode is 'compatibility' but deprecated; fail if mode=new and name_check used incorrectly
    if mode == None:
        mode = "compatibility"
    if mode == "compatibility":
        if name_check != None:
            fail("Parameter name_check can only be used with mode=new")
    else:  # mode == "new"
        if name != None and from_path != None:
            fail("Parameters 'name' and 'from_path' are mutually exclusive when 'mode=new'")

    # Determine package spec
    pkg_param = from_path if from_path else name
    if pkg_param == None:
        fail("Either 'name' or 'from_path' must be provided")

    # Mode-specific logic
    if mode == "compatibility":
        # Check if already installed
        if _is_package_installed(ctx, name, locallib, version):
            return {"changed": False, "msg": "already installed"}
        pkg_spec = pkg_param
    else:  # mode == "new"
        # Check if already installed (using name_check if provided)
        check_name = name_check if name_check != None else name
        if check_name != None and _is_package_installed(ctx, check_name, locallib, version):
            return {"changed": False, "msg": "already installed"}
        pkg_spec = _sanitize_pkg_spec_version(ctx, pkg_param, version)

    # Build command
    cmd = [executable]
    if notest:
        cmd.append("--notest")
    if locallib != None:
        cmd.extend(["--local-lib", locallib])
    if mirror != None:
        cmd.extend(["--mirror", mirror])
    if mirror_only:
        cmd.append("--mirror-only")
    if installdeps:
        cmd.append("--installdeps")
    cmd.append(pkg_spec)

    res = ctx.run(cmd, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would install " + str(pkg_param)}
    if res.rc != 0:
        fail("failed to install " + str(pkg_param) + ": " + res.stderr)
    # Detect if installation actually happened (not up-to-date)
    if "is up to date" in res.stderr or "is up to date" in res.stdout:
        return {"changed": False, "msg": "already up to date"}
    return {"changed": True, "msg": "installed " + str(pkg_param)}


def _is_package_installed(ctx, name, locallib, version):
    if name == None or name.endswith(".tar.gz"):
        return False
    ver_str = "" if version == None else " " + version

    # Build perl command to check module version
    perl_cmd = ["perl", "-le", "use " + name + ver_str + ";"]
    env = {}
    if locallib != None:
        env = {"PERL5LIB": locallib + "/lib/perl5"}

    res = ctx.run(perl_cmd, mutates=False)
    return res.rc == 0


def _sanitize_pkg_spec_version(ctx, pkg_spec, version):
    if version == None:
        return pkg_spec
    if pkg_spec.endswith(".tar.gz"):
        fail("parameter 'version' must not be used when installing from a file")
    if pkg_spec.endswith(".git"):
        if version.startswith("~"):
            fail("operator '~' not allowed in version parameter when installing from git repository")
        if not version.startswith("@"):
            version = "@" + version
        return pkg_spec + version
    if pkg_spec.endswith("/"):
        fail("parameter 'version' must not be used when installing from a directory")
    if not version.startswith("@") and not version.startswith("~"):
        version = "~" + version
    return pkg_spec + version
