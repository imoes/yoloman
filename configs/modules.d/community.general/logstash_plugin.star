def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    plugin_bin = params.get("plugin_bin", "/usr/share/logstash/bin/logstash-plugin")
    proxy_host = params.get("proxy_host")
    proxy_port = params.get("proxy_port")
    version = params.get("version")

    # Probe current state
    res = ctx.run([plugin_bin, "list", name], mutates=False)
    present = res.rc == 0

    # Idempotency: no change needed
    if (present and state == "present") or (not present and state == "absent"):
        return {"changed": False, "msg": "plugin %s already in desired state" % name}

    # Build command arguments
    cmd_args = [plugin_bin]
    if state == "present":
        cmd_args.append("install")
    elif state == "absent":
        cmd_args.append("remove")
    else:
        fail("unsupported state: " + state)
    cmd_args.append(name)

    # Append version and proxy args if present
    if state == "present":
        if version != None:
            cmd_args.append("--version")
            cmd_args.append(version)
        if proxy_host != None and proxy_port != None:
            cmd_args.append("-DproxyHost=" + proxy_host)
            cmd_args.append("-DproxyPort=" + proxy_port)

    # Execute command
    res = ctx.run(cmd_args, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would %s plugin %s" % (state, name)}

    if res.rc != 0:
        reason = res.stdout
        if "reason: " in reason:
            reason = reason.split("reason: ")[-1].strip()
        fail("failed to %s plugin %s: %s" % (state, name, reason))

    verb = "would install" if ctx.check_mode else "installed"
    if state == "absent":
        verb = "would remove" if ctx.check_mode else "removed"
    return {"changed": True, "msg": "%s plugin %s" % (verb, name)}
