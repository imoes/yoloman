def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    url = params.get("url")
    timeout = params.get("timeout", "1m")
    plugin_bin = params.get("plugin_bin", "/opt/kibana/bin/kibana")
    plugin_dir = params.get("plugin_dir", "/opt/kibana/installedPlugins/")
    version = params.get("version")
    force = params.get("force", False)
    allow_root = params.get("allow_root", False)

    # Get Kibana version
    cmd = [plugin_bin, "--version"]
    if allow_root:
        cmd.append("--allow-root")
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("Failed to get Kibana version: " + res.stderr)
    kibana_version = res.stdout.strip()

    # Determine plugin name for directory check
    repo_name = name
    slash_idx = name.find("/")
    if slash_idx != -1:
        repo_name = name[slash_idx + 1:]
    for prefix in ("elasticsearch-", "es-"):
        if repo_name.startswith(prefix):
            repo_name = repo_name[len(prefix):]
            break

    # Check if plugin is present
    plugin_path = repo_name
    if not ctx.file_exists(plugin_path) and not ctx.file_exists(plugin_dir + "/" + repo_name):
        # Try relative to plugin_dir
        plugin_path = plugin_dir + "/" + repo_name
    present = ctx.stat(plugin_path) != None and ctx.stat(plugin_path).get("is_dir", False)

    # Skip if state is already correct (unless force)
    if (present and state == "present" and not force) or (state == "absent" and not present and not force):
        return {"changed": False, "name": name, "state": state}

    # Append version if provided
    install_name = name
    if version != None:
        install_name = name + "/" + version

    # Prepare command arguments
    kibana_version_num = int(kibana_version.split(".")[0]) if kibana_version.split(".")[0].isdigit() else 4
    if kibana_version_num >= 5 or (kibana_version_num == 4 and int(kibana_version.split(".")[1]) >= 7):
        kibana_plugin_bin = plugin_bin.rsplit("/", 1)[0] + "/kibana-plugin"
        if state == "present":
            cmd_args = [kibana_plugin_bin, "install"]
            if url != None:
                cmd_args.append(url)
            else:
                cmd_args.append(install_name)
        else:
            cmd_args = [kibana_plugin_bin, "remove", install_name]
    else:
        cmd_args = [plugin_bin, "plugin"]
        if state == "present":
            cmd_args.append("--install")
        else:
            cmd_args.append("--remove")
        cmd_args.append(install_name)
        if url != None:
            cmd_args.extend(["--url", url])

    if timeout != "1m":
        cmd_args.extend(["--timeout", timeout])

    if allow_root:
        cmd_args.append("--allow-root")

    if force and state == "present":
        # Remove first
        remove_args = list(cmd_args)
        if kibana_version_num >= 5 or (kibana_version_num == 4 and int(kibana_version.split(".")[1]) >= 7):
            remove_args[1] = "remove"
        else:
            remove_args[1] = "--remove"
        res = ctx.run(remove_args, mutates=True)
        if res.skipped:
            # In check mode, removal would happen
            pass
        elif res.rc != 0:
            fail("Failed to remove plugin: " + res.stderr)

    # Execute install/remove
    if ctx.check_mode:
        return {"changed": True, "cmd": " ".join(cmd_args), "stdout": "check mode", "stderr": "", "name": install_name, "state": state, "url": url, "timeout": timeout}

    res = ctx.run(cmd_args, mutates=True)
    if res.skipped:
        return {"changed": True, "cmd": " ".join(cmd_args), "stdout": "check mode", "stderr": "", "name": install_name, "state": state, "url": url, "timeout": timeout}

    if res.rc != 0:
        reason = res.stdout
        if "reason: " in reason:
            reason = reason.split("reason: ")[-1].strip()
        fail(reason)

    return {
        "changed": True,
        "cmd": " ".join(cmd_args),
        "stdout": res.stdout,
        "stderr": res.stderr,
        "name": install_name,
        "state": state,
        "url": url,
        "timeout": timeout
    }
