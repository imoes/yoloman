def main(ctx, params):
    name = params.get("name")
    path = params.get("path")
    version = params.get("version")
    glbl = params.get("global", False)
    state = params.get("state", "present")
    executable = params.get("executable")
    ignore_scripts = params.get("ignore_scripts", False)
    unsafe_perm = params.get("unsafe_perm", False)
    production = params.get("production", False)
    registry = params.get("registry")
    no_optional = params.get("no_optional", False)
    no_bin_links = params.get("no_bin_links", False)
    ci = params.get("ci", False)

    # Validation
    if not path and not glbl:
        fail("path must be specified when not using global")
    if state == "absent" and name == None:
        fail("name is required when state is absent")

    # Build npm executable path
    if executable != None:
        npm_cmd = executable.split(" ")
    else:
        npm_cmd = ["npm"]

    # Build base args
    base_args = list(npm_cmd)
    if glbl:
        base_args.append("--global")
    if production:
        base_args.append("--production")
    if ignore_scripts:
        base_args.append("--ignore-scripts")
    if unsafe_perm:
        base_args.append("--unsafe-perm")
    if no_optional:
        base_args.append("--no-optional")
    if no_bin_links:
        base_args.append("--no-bin-links")
    if registry != None:
        base_args.extend(["--registry", registry])

    # Determine working directory
    cwd = path
    if path != None and not ctx.file_exists(path):
        fail("path %s does not exist" % path)
    if path != None and not ctx.stat(path).get("is_dir", False):
        fail("path %s is not a directory" % path)

    # State: ci (npm ci)
    if ci:
        res = ctx.run(base_args + ["ci"], mutates=True, cwd=cwd)
        if res.skipped:
            return {"changed": True, "msg": "would run npm ci"}
        if res.rc != 0:
            fail("npm ci failed: " + res.stderr)
        return {"changed": True, "msg": "ran npm ci"}

    # Helper: list installed packages (npm list --json --long)
    def list_packages():
        res = ctx.run(base_args + ["list", "--json", "--long"], mutates=False, cwd=cwd, ok_codes=[0,1])
        if res.rc != 0:
            # Non-zero exit on list is common when nothing installed; treat as empty
            if name != None:
                return [], [name]
            return [], []
        data = res.stdout
        # Parse JSON manually (no json module)
        if not data.strip():
            if name != None:
                return [], [name]
            return [], []
        # Basic JSON parsing for dependencies structure (simplified)
        installed = []
        missing = []
        deps_start = data.find('"dependencies"')
        if deps_start == -1:
            if name != None:
                return [], [name]
            return [], []
        # Extract dependencies dict substring by counting braces
        brace_count = 0
        i = deps_start
        while i < len(data):
            if data[i] == '{':
                brace_count += 1
            elif data[i] == '}':
                brace_count -= 1
                if brace_count == 0:
                    break
            i += 1
        deps_str = data[deps_start:i+1]
        # Parse simple key-value pairs (ignoring nested objects)
        pos = 0
        while True:
            key_start = deps_str.find('"', pos)
            if key_start == -1:
                break
            key_end = deps_str.find('"', key_start + 1)
            if key_end == -1:
                break
            dep_name = deps_str[key_start+1:key_end]
            # Skip known keys
            if dep_name in ["version", "resolved", "integrity", "from", "requires"]:
                pos = key_end + 1
                continue
            # Check if this dep is marked as missing or invalid
            after_key = deps_str.find(':', key_end + 1)
            if after_key == -1:
                pos = key_end + 1
                continue
            next_brace = deps_str.find('{', after_key)
            if next_brace == -1:
                pos = key_end + 1
                continue
            obj_str = deps_str[next_brace:]
            if '"missing": true' in obj_str or '"invalid": true' in obj_str:
                missing.append(dep_name)
            else:
                installed.append(dep_name)
            pos = key_end + 1
        # Check for specific package if provided
        if name != None:
            # Check if package is installed
            found = False
            for pkg in installed:
                if pkg == name or pkg.startswith(name + '@'):
                    found = True
                    break
            if not found:
                missing.append(name)
        return installed, missing

    # State: absent
    if state == "absent":
        installed, missing = list_packages()
        if name in installed:
            res = ctx.run(base_args + ["uninstall", name], mutates=True, cwd=cwd)
            if res.skipped:
                return {"changed": True, "msg": "would uninstall " + name}
            if res.rc != 0:
                fail("npm uninstall failed: " + res.stderr)
            return {"changed": True, "msg": "uninstalled " + name}
        return {"changed": False, "msg": name + " is not installed"}

    # State: present or latest
    installed, missing = list_packages()
    changed = False
    msg = ""

    # Install if missing
    if name in missing:
        if state == "latest":
            msg = "installed "
        else:
            msg = "installed "
        args = ["install"]
        if ci:
            args = ["ci"]
        if version != None:
            pkg_name = name + '@' + str(version)
        else:
            pkg_name = name
        args.append(pkg_name)
        res = ctx.run(base_args + args, mutates=True, cwd=cwd)
        if res.skipped:
            return {"changed": True, "msg": "would install " + name}
        if res.rc != 0:
            fail("npm install failed: " + res.stderr)
        changed = True

    # State: latest - check for outdated packages
    if state == "latest":
        # Get outdated packages (npm outdated)
        res = ctx.run(base_args + ["outdated"], mutates=False, cwd=cwd, ok_codes=[0,1])
        if not res.skipped and res.rc == 0:
            outdated_pkgs = []
            for line in res.stdout.splitlines():
                if line.strip() != "":
                    # Parse: package@oldver expected@ver registry@ver
                    # Extract package name (first part)
                    parts = line.split()
                    if len(parts) > 0:
                        pkg_name = parts[0]
                        # Remove version if present (name@version)
                        if '@' in pkg_name:
                            pkg_name = pkg_name.split('@')[0]
                        outdated_pkgs.append(pkg_name)
            if name != None and name in outdated_pkgs:
                res = ctx.run(base_args + ["update", name], mutates=True, cwd=cwd)
                if res.skipped:
                    return {"changed": True, "msg": "would update " + name}
                if res.rc != 0:
                    fail("npm update failed: " + res.stderr)
                changed = True
                msg = "updated " + name
            elif name == None:
                # Update all outdated if no specific package
                if outdated_pkgs != []:
                    res = ctx.run(base_args + ["update"], mutates=True, cwd=cwd)
                    if res.skipped:
                        return {"changed": True, "msg": "would update packages"}
                    if res.rc != 0:
                        fail("npm update failed: " + res.stderr)
                    changed = True
                    msg = "updated packages"

    if not changed:
        msg = name + " already installed"
    return {"changed": changed, "msg": msg}
