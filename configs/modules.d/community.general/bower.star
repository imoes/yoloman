def main(ctx, params):
    name = params.get("name")
    offline = params.get("offline", False)
    production = params.get("production", False)
    path = params["path"]
    relative_execpath = params.get("relative_execpath")
    state = params.get("state", "present")
    version = params.get("version")

    # Validate required conditions
    if state == "absent" and name == None:
        fail("uninstalling a package is only available for named packages")

    # Build bower command base
    if relative_execpath:
        bower_exe = ctx.file_join([path, relative_execpath, "bower"])
        if not ctx.file_exists(bower_exe):
            fail("bower not found at relative path " + relative_execpath)
    else:
        bower_exe = "bower"

    def run_bower(args, run_in_check_mode=False, check_rc=True):
        """Run bower command with appropriate flags and cwd."""
        if not ctx.check_mode or (ctx.check_mode and run_in_check_mode):
            cmd = [bower_exe]
            cmd.extend(args)
            cmd.extend(["--config.interactive=false", "--allow-root"])
            if name != None:
                if version != None:
                    cmd.append(name + "#" + version)
                else:
                    cmd.append(name)
            if offline:
                cmd.append("--offline")
            if production:
                cmd.append("--production")
            # Ensure path exists as directory
            if not ctx.file_exists(path):
                ctx.file_write(ctx.file_join([path, ".placeholder"]), "", mode="0755")
            stat = ctx.stat(path)
            if stat == None or not stat.get("is_dir", False):
                fail("path " + path + " is not a directory")
            res = ctx.run(cmd, mutates=True, ok_codes=[0, 1] if not check_rc else [0])
            if check_rc and res.rc != 0:
                fail("bower command failed: " + res.stderr)
            return res.stdout
        return ""

    def list_packages():
        """Get installed/missing/outdated lists from 'bower list --json'."""
        out = run_bower(["list", "--json"], run_in_check_mode=True, check_rc=False)
        installed = []
        missing = []
        outdated = []
        if out.strip() == "":
            # No output means nothing installed or error
            if name != None:
                missing.append(name)
            return installed, missing, outdated
        data = json.loads(out)
        if "dependencies" in data:
            for dep in data["dependencies"]:
                dep_data = data["dependencies"][dep]
                if isinstance(dep_data, dict):
                    if dep_data.get("missing", False):
                        missing.append(dep)
                    elif (dep_data.get("pkgMeta") and
                          isinstance(dep_data.get("pkgMeta"), dict) and
                          dep_data.get("update") and
                          isinstance(dep_data.get("update"), dict) and
                          dep_data["pkgMeta"].get("version") != dep_data["update"].get("latest")):
                        outdated.append(dep)
                    elif dep_data.get("incompatible", False):
                        outdated.append(dep)
                    else:
                        installed.append(dep)
        else:
            # Named dependency not installed
            if name != None:
                missing.append(name)
        return installed, missing, outdated

    # Perform state-specific action
    changed = False
    if state == "present":
        installed, missing, outdated = list_packages()
        if name == None:
            # No package name specified; assume idempotent if bower.json exists and no missing
            if ctx.file_exists(ctx.file_join([path, "bower.json"])):
                if missing:
                    changed = True
                    run_bower(["install"], mutates=True)
        else:
            if name in missing:
                changed = True
                run_bower(["install"], mutates=True)
    elif state == "latest":
        installed, missing, outdated = list_packages()
        if name == None:
            # Update all packages
            if missing or outdated:
                changed = True
                run_bower(["update"], mutates=True)
        else:
            if name in missing or name in outdated:
                changed = True
                run_bower(["update"], mutates=True)
    else:  # absent
        installed, missing, outdated = list_packages()
        if name in installed:
            changed = True
            run_bower(["uninstall"], mutates=True)

    if changed and ctx.check_mode:
        return {"changed": True, "msg": "would update packages"}
    return {"changed": changed, "msg": "done"}
