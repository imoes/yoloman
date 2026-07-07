def parse_plugin_repo(name):
    elements = name.split("/")
    repo = elements[0]
    if len(elements) > 1:
        repo = elements[1]
    for prefix in ("elasticsearch-", "es-"):
        if repo.startswith(prefix):
            return repo[len(prefix):]
    return repo


def is_plugin_present(plugin_name, plugin_dir, ctx):
    return ctx.stat(plugin_dir + "/" + plugin_name) != None and ctx.stat(plugin_dir + "/" + plugin_name).get("is_dir", False)


def parse_error(output):
    marker = "ERROR: "
    idx = output.find(marker)
    if idx != -1:
        return output[idx + len(marker):].strip()
    return output.strip()


def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    src = params.get("src")
    url = params.get("url")
    timeout = params.get("timeout", "1m")
    force = params.get("force", False)
    plugin_bin = params.get("plugin_bin")
    plugin_dir = params.get("plugin_dir", "/usr/share/elasticsearch/plugins/")
    proxy_host = params.get("proxy_host")
    proxy_port = params.get("proxy_port")
    version = params.get("version")

    # Determine plugin binary path
    valid_plugin_bin = None
    if plugin_bin != None and ctx.file_exists(plugin_bin):
        valid_plugin_bin = plugin_bin
    else:
        # Try known paths
        for path in ["/usr/share/elasticsearch/bin/elasticsearch-plugin",
                     "/usr/share/elasticsearch/bin/plugin"]:
            if valid_plugin_bin == None and ctx.file_exists(path):
                valid_plugin_bin = path
        # If not found yet and plugin_bin was provided, try its basename in default dirs
        if valid_plugin_bin == None and plugin_bin != None:
            bin_name = plugin_bin
            if "/" in bin_name:
                bin_name = bin_name.split("/")[-1]
            for dir_path in ["/usr/share/elasticsearch/bin", "/usr/bin"]:
                full_path = dir_path + "/" + bin_name
                if ctx.file_exists(full_path):
                    valid_plugin_bin = full_path
                    break

    if valid_plugin_bin == None:
        fail("No valid elasticsearch-plugin binary found. Make sure Elasticsearch is installed.")

    plugin_bin = valid_plugin_bin
    repo = parse_plugin_repo(name)
    present = is_plugin_present(repo, plugin_dir, ctx)

    # Idempotency check
    if (state == "present" and present) or (state == "absent" and not present):
        return {"changed": False, "msg": "Plugin '" + name + "' state already " + state}

    # Check mode handling
    if ctx.check_mode:
        if state == "present":
            return {"changed": True, "msg": "would install plugin " + name}
        else:
            return {"changed": True, "msg": "would remove plugin " + name}

    # Build command
    cmd_args = [plugin_bin, "install" if state == "present" else "remove"]
    is_old_bin = (plugin_bin.split("/")[-1] == "plugin")

    if state == "present":
        if is_old_bin:
            if timeout:
                cmd_args.append("--timeout")
                cmd_args.append(timeout)
            if version:
                cmd_args[-1] = name + "/" + version
                cmd_args.append(name + "/" + version)
        if proxy_host != None and proxy_port != None:
            cmd_args.append("-DproxyHost=" + proxy_host)
            cmd_args.append("-DproxyPort=" + proxy_port)
        if force:
            cmd_args.append("--batch")
        if src != None:
            cmd_args.append(src)
        elif url != None:
            cmd_args.append("--url")
            cmd_args.append(url)
        else:
            cmd_args.append(name)
    else:
        cmd_args.append(repo)

    res = ctx.run(cmd_args, mutates=True)
    if res.skipped:
        if state == "present":
            return {"changed": True, "msg": "would install plugin " + name}
        else:
            return {"changed": True, "msg": "would remove plugin " + name}

    if res.rc != 0:
        fail("Plugin " + ("installation" if state == "present" else "removal") + " failed: " + parse_error(res.stdout))

    return {"changed": True, "msg": "Plugin '" + name + "' successfully " + ("installed" if state == "present" else "removed")}
