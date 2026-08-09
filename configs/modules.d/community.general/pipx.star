def main(ctx, params):
    state = params.get("state", "install")
    name = params.get("name")
    source = params.get("source")
    force = params.get("force", False)
    include_injected = params.get("include_injected", False)
    install_deps = params.get("install_deps", False)
    install_apps = params.get("install_apps", False)
    index_url = params.get("index_url")
    python = params.get("python")
    system_site_packages = params.get("system_site_packages", False)
    editable = params.get("editable", False)
    pip_args = params.get("pip_args")
    executable = params.get("executable")
    inject_packages = params.get("inject_packages", [])

    # Validate required parameters per state
    if state in ("present", "install", "absent", "uninstall", "upgrade", "reinstall", "latest"):
        if name == None:
            fail("name is required for state " + state)
    if state == "inject":
        if name == None:
            fail("name is required for state inject")
        if inject_packages == None or len(inject_packages) == 0:
            fail("inject_packages is required for state inject")

    # Build pipx command
    cmd = [executable] if executable != None else None
    if cmd == None:
        # Fallback: use python -m pipx, but we cannot get ansible's Python interpreter reliably
        # So we just fail if executable not provided and we need to run pipx
        fail("executable is required when not using the system pipx (cannot infer Python interpreter in Starlark)")

    # Helper to run pipx commands
    def run_pipx(argv, mutates=True):
        res = ctx.run(cmd + argv, mutates=mutates)
        if res.skipped:
            return res
        if res.rc != 0:
            fail("pipx command failed: " + res.stderr)
        return res

    # Check installed apps using pipx list --json
    def get_installed():
        res = run_pipx(["list", "--json"], mutates=False)
        if res.skipped:
            return {}
        raw = res.stdout.strip()
        if raw == "":
            return {}
        # Minimal parsing: look for app names in JSON structure
        apps = {}
        # Find the start of venvs section
        venvs_idx = raw.find('"venvs"')
        if venvs_idx == -1:
            return {}
        # Start parsing after "venvs"
        start = raw.find('{', venvs_idx)
        if start == -1:
            return {}
        # Simple scan: extract key-value pairs where key is app name and value has package_version
        i = start + 1
        while i < len(raw):
            # Skip whitespace
            while i < len(raw) and (raw[i] == ' ' or raw[i] == '\n' or raw[i] == '\t'):
                i += 1
            if i >= len(raw):
                break
            # Expecting a string key (app name)
            if raw[i] != '"':
                i += 1
                continue
            # Extract key
            i += 1
            key_start = i
            while i < len(raw) and raw[i] != '"':
                i += 1
            app_name = raw[key_start:i]
            i += 1  # skip closing quote
            # Skip whitespace and colon
            while i < len(raw) and (raw[i] == ' ' or raw[i] == '\n' or raw[i] == '\t' or raw[i] == ':'):
                i += 1
            # Expecting opening brace for object
            if i >= len(raw) or raw[i] != '{':
                continue
            # Look ahead for "package_version" within this object
            obj_start = i
            depth = 1
            i += 1
            found_version = False
            version_str = ""
            while i < len(raw) and depth > 0:
                if raw[i] == '{':
                    depth += 1
                elif raw[i] == '}':
                    depth -= 1
                # Check for package_version inside this scope
                if not found_version and raw[i:i+17] == '"package_version"':
                    j = i + 17
                    # Skip whitespace and colon
                    while j < len(raw) and (raw[j] == ' ' or raw[j] == '\n' or raw[j] == '\t' or raw[j] == ':'):
                        j += 1
                    if j < len(raw) and raw[j] == '"':
                        j += 1
                        ver_start = j
                        while j < len(raw) and raw[j] != '"':
                            j += 1
                        version_str = raw[ver_start:j]
                        found_version = True
                i += 1
            if found_version and app_name != "":
                apps[app_name] = {"version": version_str}
        return apps

    installed = get_installed()
    is_installed = installed.get(name) != None

    # Handle state aliases
    if state == "present":
        state = "install"
    elif state == "absent":
        state = "uninstall"

    changed = False
    msg = ""

    if state == "install":
        if not is_installed or force:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would install " + (source if source != None else name)}
            # Build install args
            argv = ["install", name if source == None else source]
            if index_url != None:
                argv += ["--index-url", index_url]
            if install_deps:
                argv.append("--include-deps")
            if force:
                argv.append("--force")
            if python != None:
                argv += ["--python", python]
            if system_site_packages:
                argv.append("--system-site-packages")
            if editable:
                argv.append("--editable")
            if pip_args != None:
                argv += ["--pip-args", pip_args]
            res = run_pipx(argv)
            return {"changed": True, "msg": "installed " + (source if source != None else name)}

    elif state == "upgrade":
        if not is_installed:
            fail("cannot upgrade " + name + ": not installed")
        if force:
            changed = True
        if ctx.check_mode:
            return {"changed": changed, "msg": "would upgrade " + name}
        argv = ["upgrade", name]
        if include_injected:
            argv.append("--include-injected")
        if index_url != None:
            argv += ["--index-url", index_url]
        if force:
            argv.append("--force")
        if editable:
            argv.append("--editable")
        if pip_args != None:
            argv += ["--pip-args", pip_args]
        res = run_pipx(argv)
        return {"changed": True, "msg": "upgraded " + name}

    elif state == "uninstall":
        if is_installed:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would uninstall " + name}
            res = run_pipx(["uninstall", name])
            return {"changed": True, "msg": "uninstalled " + name}
        else:
            return {"changed": False, "msg": name + " not installed"}

    elif state == "reinstall":
        if not is_installed:
            fail("cannot reinstall " + name + ": not installed")
        changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "would reinstall " + name}
        argv = ["reinstall", name]
        if python != None:
            argv += ["--python", python]
        res = run_pipx(argv)
        return {"changed": True, "msg": "reinstalled " + name}

    elif state == "inject":
        if not is_installed:
            fail("cannot inject packages into " + name + ": not installed")
        if force:
            changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "would inject " + str(inject_packages) + " into " + name}
        argv = ["inject", name]
        for pkg in inject_packages:
            argv.append(pkg)
        if index_url != None:
            argv += ["--index-url", index_url]
        if install_apps:
            argv.append("--inject-apps")
        if install_deps:
            argv.append("--include-deps")
        if force:
            argv.append("--force")
        if editable:
            argv.append("--editable")
        if pip_args != None:
            argv += ["--pip-args", pip_args]
        res = run_pipx(argv)
        return {"changed": True, "msg": "injected packages into " + name}

    elif state == "upgrade_all":
        if force:
            changed = True
        if ctx.check_mode:
            return {"changed": changed, "msg": "would upgrade all apps"}
        argv = ["upgrade-all"]
        if include_injected:
            argv.append("--include-injected")
        if force:
            argv.append("--force")
        res = run_pipx(argv)
        return {"changed": True, "msg": "upgraded all apps"}

    elif state == "reinstall_all":
        changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "would reinstall all apps"}
        argv = ["reinstall-all"]
        if python != None:
            argv += ["--python", python]
        res = run_pipx(argv)
        return {"changed": True, "msg": "reinstalled all apps"}

    elif state == "uninstall_all":
        changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "would uninstall all apps"}
        res = run_pipx(["uninstall-all"])
        return {"changed": True, "msg": "uninstalled all apps"}

    elif state == "latest":
        # Simulate install + upgrade
        if not is_installed or force:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would install (latest) " + (source if source != None else name)}
            argv = ["install", name if source == None else source]
            if index_url != None:
                argv += ["--index-url", index_url]
            if install_deps:
                argv.append("--include-deps")
            if force:
                argv.append("--force")
            if python != None:
                argv += ["--python", python]
            if system_site_packages:
                argv.append("--system-site-packages")
            if editable:
                argv.append("--editable")
            if pip_args != None:
                argv += ["--pip-args", pip_args]
            run_pipx(argv)
        # Then upgrade
        if ctx.check_mode:
            return {"changed": True, "msg": "would install and upgrade " + (source if source != None else name)}
        argv = ["upgrade", name]
        if include_injected:
            argv.append("--include-injected")
        if index_url != None:
            argv += ["--index-url", index_url]
        if force:
            argv.append("--force")
        if editable:
            argv.append("--editable")
        if pip_args != None:
            argv += ["--pip-args", pip_args]
        run_pipx(argv)
        return {"changed": True, "msg": "installed and upgraded " + (source if source != None else name)}

    fail("unsupported state: " + state)
