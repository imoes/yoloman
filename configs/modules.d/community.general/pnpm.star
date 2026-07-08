def main(ctx, params):
    # Extract parameters
    name = params.get("name")
    alias = params.get("alias")
    path = params.get("path")
    version = params.get("version")
    executable = params.get("executable")
    ignore_scripts = params.get("ignore_scripts", False)
    no_optional = params.get("no_optional", False)
    production = params.get("production", False)
    dev = params.get("dev", False)
    optional = params.get("optional", False)
    state = params.get("state", "present")
    globally = params.get("global", False)

    # Validation: version without name
    if name == None and version != None:
        fail("version is meaningless when name is not provided")

    # Validation: alias without name
    if name == None and alias != None:
        fail("alias is meaningless when name is not provided")

    # Validation: path and global mutual exclusivity
    if globally:
        if path != None:
            fail("Cannot specify path when doing global installation")
    else:
        if path == None:
            fail("path must be specified when not using global")

    # Validation: global options (production/dev/optional) with global install
    if globally and (production or dev or optional):
        fail("Options production, dev, and optional is meaningless when installing packages globally")

    # Validation: conflicting options
    if production and dev and optional:
        fail("Options production and dev and optional don't go together")
    if production and dev:
        fail("Options production and dev don't go together")
    if production and optional:
        fail("Options production and optional don't go together")
    if dev and optional:
        fail("Options dev and optional don't go together")

    # Validation: remote URL with semver
    if name != None and name.find("http") == 0 and version != None:
        fail("Semver not supported on remote url downloads")

    # Validation: optional without name
    if optional and name == None:
        fail("Optional not available when package name not provided, use no_optional instead")

    # Validation: absent state requires name
    if state == "absent" and name == None:
        fail("Package name is required for uninstalling")

    # Determine pnpm executable
    if executable != None:
        pnpm_cmd = executable.split(" ")
    else:
        # Use which to locate pnpm in PATH
        res = ctx.run(["which", "pnpm"])
        if res.rc != 0:
            fail("pnpm executable not found in PATH")
        pnpm_cmd = [res.stdout.strip()]

    # Determine install path for global mode
    if globally:
        res = ctx.run(pnpm_cmd + ["root", "-g"])
        if res.rc != 0:
            fail("Failed to get global pnpm root: " + res.stderr)
        root = res.stdout.strip()
        # Get parent directory of node_modules
        path = root.rsplit("/", 1)[0]

    # Build command prefix parts
    cmd_base = pnpm_cmd[:]
    cmd_flags = []

    if globally:
        cmd_flags.append("-g")

    if ignore_scripts:
        cmd_flags.append("--ignore-scripts")

    if no_optional:
        cmd_flags.append("--no-optional")

    if production:
        cmd_flags.append("-P")

    if dev:
        cmd_flags.append("-D")

    # Handle optional: only for specific package install
    if optional and name != None:
        cmd_flags.append("-O")

    # Determine package spec string
    pkg_spec = None
    if name != None:
        pkg_spec = name
        if version != None:
            pkg_spec = pkg_spec + "@" + version
        else:
            pkg_spec = pkg_spec + "@latest"
        if alias != None:
            pkg_spec = alias + "@npm:" + pkg_spec

    # Helper: run command in cwd=path
    def run_in_path(cmd, mutates=False):
        return ctx.run(cmd, mutates=mutates)

    # Check if package is installed (missing)
    def is_missing():
        # If no package.json in path, assume missing
        if not ctx.file_exists(path + "/package.json"):
            return True

        # List packages in JSON format
        cmd = cmd_base + ["list", "--json"]
        if name != None:
            cmd.append(name)

        res = run_in_path(cmd, mutates=False)
        if res.rc != 0:
            # Error implies missing
            return True

        out = res.stdout.strip()
        if not out.startswith("{"):
            return True

        # Check for "error" key in output using substring search
        if out.find('"error"') != -1:
            return True

        # If no package specified, assume installed if package.json exists
        if name == None:
            return False

        # Simple heuristic: check if package name appears in output
        # Given Starlark limitations, use substring search
        if out.find('"' + name + '"') == -1:
            return True

        # If version specified, check version match using substring search
        if version != None:
            idx = out.find('"' + name + '"')
            if idx == -1:
                return True
            # Extract segment after package name
            section = out[idx:idx+2000]
            ver_idx = section.find('"version"')
            if ver_idx == -1:
                return True
            # Find the colon after "version"
            colon_idx = section.find(':', ver_idx)
            if colon_idx == -1:
                return True
            # Find opening quote after colon
            quote_idx = section.find('"', colon_idx)
            if quote_idx == -1:
                return True
            # Find closing quote
            end_quote = section.find('"', quote_idx+1)
            if end_quote == -1:
                return True
            installed_ver = section[quote_idx+1:end_quote]
            if installed_ver != version:
                return True
        return False

    # Install function
    def do_install():
        cmd = cmd_base[:]
        if pkg_spec != None:
            cmd.extend(["add", pkg_spec])
        else:
            cmd.append("install")
        cmd.extend(cmd_flags)
        res = run_in_path(cmd, mutates=True)
        if res.skipped:
            return res
        if res.rc != 0:
            fail("pnpm install failed: " + res.stderr)
        return res

    # Update function
    def do_update():
        cmd = cmd_base + ["update", "--latest"]
        cmd.extend(cmd_flags)
        res = run_in_path(cmd, mutates=True)
        if res.skipped:
            return res
        if res.rc != 0:
            fail("pnpm update failed: " + res.stderr)
        return res

    # Uninstall function
    def do_uninstall():
        if alias != None:
            cmd = cmd_base + ["remove", alias]
        else:
            cmd = cmd_base + ["remove", name]
        cmd.extend(cmd_flags)
        res = run_in_path(cmd, mutates=True)
        if res.skipped:
            return res
        if res.rc != 0:
            fail("pnpm remove failed: " + res.stderr)
        return res

    # Check outdated (for state=latest)
    def get_outdated():
        if not ctx.file_exists(path + "/pnpm-lock.yaml"):
            return []
        cmd = cmd_base + ["outdated", "--format", "json"]
        res = run_in_path(cmd, mutates=False)
        if res.rc != 0:
            return []
        out = res.stdout.strip()
        if not out.startswith("{"):
            return []
        # Starlark can't parse JSON, so use simple heuristic
        return out if out else []

    # Execute state logic
    changed = False
    msg = ""
    if state == "present":
        if is_missing():
            changed = True
            res = do_install()
            if res.skipped:
                msg = "would install " + (name if name else "packages")
            else:
                msg = "installed " + (name if name else "packages")
        else:
            msg = name + " already present" if name else "packages already present"
    elif state == "latest":
        outdated = get_outdated()
        is_outdated = False
        if name != None:
            if is_missing():
                is_outdated = True
            else:
                is_outdated = len(outdated) > 0 if outdated else False
        else:
            is_outdated = len(outdated) > 0 if outdated else False

        if is_outdated:
            changed = True
            res = do_install() if name != None else do_update()
            if res.skipped:
                msg = "would update packages to latest"
            else:
                msg = "updated packages to latest"
        else:
            msg = "packages already at latest version"
    else:  # absent
        if not is_missing():
            changed = True
            res = do_uninstall()
            if res.skipped:
                msg = "would uninstall " + (name if name else "package")
            else:
                msg = "uninstalled " + (name if name else "package")
        else:
            msg = name + " not installed, nothing to uninstall" if name else "nothing to uninstall"

    return {"changed": changed, "msg": msg}
