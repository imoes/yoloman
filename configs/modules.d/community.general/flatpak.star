def main(ctx, params):
    # Parse parameters
    names = params["name"]
    state = params.get("state", "present")
    remote = params.get("remote", "flathub")
    method = params.get("method", "system")
    no_deps = params.get("no_dependencies", False)
    executable = params.get("executable", "flatpak")

    # Validate method
    if method not in ("system", "user"):
        fail("Invalid method: " + method + ". Must be 'system' or 'user'.")

    # Check executable exists
    res = ctx.run([executable, "--version"], ok_codes=[0, 127])
    if res.rc != 0 or "flatpak" not in res.stdout.lower():
        fail("Executable '" + executable + "' was not found on the system.")

    # Get installed flatpaks
    list_cmd = [executable, "list", "--" + method]
    res = ctx.run(list_cmd, mutates=False)
    installed_output = res.stdout.lower()
    installed_refs = []
    not_installed_refs = []

    for name_item in names:
        parsed_name = _parse_flatpak_name(name_item).lower()
        if parsed_name in installed_output:
            installed_refs.append(name_item)
        else:
            not_installed_refs.append(name_item)

    # Handle present state
    if state == "present":
        if not not_installed_refs:
            return {"changed": False, "msg": "All flatpaks are already present"}
        # Install missing flatpaks
        if ctx.check_mode:
            return {"changed": True, "msg": "would install flatpaks: " + ", ".join(not_installed_refs)}
        # Build install command
        install_cmd = [executable, "install", "--" + method]
        # Version check for --noninteractive flag
        ver_res = ctx.run([executable, "--version"])
        version = ver_res.stdout.split()[1] if ver_res.rc == 0 else "0.0.0"
        if version < "1.1.3":
            install_cmd += ["-y"]
        else:
            install_cmd += ["--noninteractive"]
        if no_deps:
            install_cmd += ["--no-deps"]

        # Process URIs and IDs separately
        uri_names = [n for n in not_installed_refs if n.startswith("http://") or n.startswith("https://")]
        id_names = [n for n in not_installed_refs if n not in uri_names]

        if uri_names:
            install_uri_cmd = install_cmd + uri_names
            res = ctx.run(install_uri_cmd, mutates=True, ok_codes=[0, 1])
            if res.rc != 0:
                fail("Failed to install URIs: " + res.stderr)
        if id_names:
            install_id_cmd = install_cmd + [remote] + id_names
            res = ctx.run(install_id_cmd, mutates=True, ok_codes=[0, 1])
            if res.rc != 0:
                fail("Failed to install IDs: " + res.stderr)
        return {"changed": True, "msg": "Installed flatpaks: " + ", ".join(not_installed_refs)}

    # Handle absent state
    if state == "absent":
        if not installed_refs:
            return {"changed": False, "msg": "All flatpaks are already absent"}
        # Uninstall existing flatpaks
        if ctx.check_mode:
            return {"changed": True, "msg": "would uninstall flatpaks: " + ", ".join(installed_refs)}

        # Build uninstall command
        uninstall_cmd = [executable, "uninstall", "--" + method]
        ver_res = ctx.run([executable, "--version"])
        version = ver_res.stdout.split()[1] if ver_res.rc == 0 else "0.0.0"
        if version < "1.1.3":
            uninstall_cmd += ["-y"]
        else:
            uninstall_cmd += ["--noninteractive"]

        # Match installed refs properly
        uninstall_refs = []
        for ref in installed_refs:
            matched = _match_installed_flat_name(ctx, executable, ref, method)
            if matched:
                uninstall_refs.append(matched)
            else:
                fail("Could not match any installed flatpak for: " + _parse_flatpak_name(ref))

        if uninstall_refs:
            uninstall_cmd += uninstall_refs
            res = ctx.run(uninstall_cmd, mutates=True, ok_codes=[0, 1])
            if res.rc != 0:
                fail("Failed to uninstall: " + res.stderr)
        return {"changed": True, "msg": "Uninstalled flatpaks: " + ", ".join(installed_refs)}


def _parse_flatpak_name(name):
    if name.startswith("http://") or name.startswith("https://"):
        # Extract filename from URL
        path = name.split("://")[-1]
        file_name = path.split("/")[-1]
        # Remove extension(s)
        parts = file_name.split(".")
        if len(parts) > 1:
            return ".".join(parts[:-1])
        else:
            return file_name
    else:
        return name


def _match_installed_flat_name(ctx, binary, name, method):
    parsed_name = _parse_flatpak_name(name).lower()
    list_cmd = [binary, "list", "--" + method, "--app", "--columns=application"]
    res = ctx.run(list_cmd, mutates=False, ok_codes=[0, 1])
    if res.rc != 0:
        return None
    for line in res.stdout.splitlines():
        if parsed_name == line.lower().strip():
            return line.strip()
    # Fallback for older flatpak versions without --columns
    list_cmd = [binary, "list", "--" + method, "--app"]
    res = ctx.run(list_cmd, mutates=False, ok_codes=[0, 1])
    if res.rc != 0:
        return None
    for line in res.stdout.splitlines():
        if parsed_name in line.lower():
            return line.split()[0].strip()
    return None
