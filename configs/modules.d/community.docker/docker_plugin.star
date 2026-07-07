def main(ctx, params):
    # Extract required and optional parameters
    plugin_name = params["plugin_name"]
    state = params.get("state", "present")
    alias = params.get("alias")
    plugin_options = params.get("plugin_options", {})
    force_remove = params.get("force_remove", False)
    enable_timeout = params.get("enable_timeout", 0)

    # Compute preferred name (alias or plugin_name)
    preferred_name = alias if alias != None else plugin_name

    # Helper: parse environment-style options list to dict
    def parse_options_list(env_list):
        if not env_list:
            return {}
        result = {}
        for item in env_list:
            if item != None and "=" in item:
                parts = item.split("=", 1)
                k = parts[0]
                v = parts[1] if len(parts) > 1 else ""
                result[k] = v
            elif item != None:
                result[item] = ""
        return result

    # Helper: prepare options dict to list
    def prepare_options_dict(opt_dict):
        if not opt_dict:
            return []
        return [str(k) + "=" + (str(v) if v != None else "") for k, v in sorted(opt_dict.items())]

    # Check if plugin exists by inspecting it
    res = ctx.run(
        ["docker", "plugin", "inspect", preferred_name],
        mutates=False,
        ok_codes=[0, 1]
    )

    existing_plugin = None
    if res.rc == 0:
        # Parse JSON output manually (no json module) — only check if Enabled is present
        if '"Enabled": true' in res.stdout or '"Enabled":true' in res.stdout:
            existing_plugin = {"Enabled": True}
        elif '"Enabled": false' in res.stdout or '"Enabled":false' in res.stdout:
            existing_plugin = {"Enabled": False}
        else:
            existing_plugin = {"Enabled": False}

    # Track actions
    actions = []

    # State handling
    if state == "present":
        if existing_plugin == None:
            # Install
            if not ctx.check_mode:
                cmd = ["docker", "plugin", "install", plugin_name]
                if alias:
                    cmd.extend(["--name", alias])
                if plugin_options:
                    for k, v in sorted(plugin_options.items()):
                        cmd.append("--set")
                        cmd.append(str(k) + "=" + str(v))
                res = ctx.run(cmd, mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to install plugin: " + res.stderr)
            actions.append("Installed plugin " + preferred_name)
            changed = True
        else:
            # Already installed: check options difference
            res = ctx.run(
                ["docker", "plugin", "inspect", "--format", "{{.Settings.Env}}", preferred_name],
                mutates=False,
                ok_codes=[0]
            )
            current_opts = parse_options_list(res.stdout.strip().split("\n") if res.stdout.strip() else [])
            desired_opts = prepare_options_dict(plugin_options)

            # Compare sorted lists
            if sorted(current_opts) != sorted(desired_opts):
                if not ctx.check_mode:
                    if plugin_options:
                        cmd = ["docker", "plugin", "set", preferred_name]
                        for k, v in sorted(plugin_options.items()):
                            cmd.append(str(k) + "=" + str(v))
                        res = ctx.run(cmd, mutates=True, ok_codes=[0])
                        if res.rc != 0:
                            fail("Failed to set plugin options: " + res.stderr)
                actions.append("Updated plugin " + preferred_name + " settings")
                changed = True
            else:
                changed = False

    elif state == "absent":
        if existing_plugin == None:
            changed = False
        else:
            if not ctx.check_mode:
                cmd = ["docker", "plugin", "remove"]
                if force_remove:
                    cmd.append("--force")
                cmd.append(preferred_name)
                res = ctx.run(cmd, mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to remove plugin: " + res.stderr)
            actions.append("Removed plugin " + preferred_name)
            changed = True

    elif state == "enable":
        if existing_plugin == None:
            # Install and enable
            if not ctx.check_mode:
                cmd = ["docker", "plugin", "install", plugin_name]
                if alias:
                    cmd.extend(["--name", alias])
                if plugin_options:
                    for k, v in sorted(plugin_options.items()):
                        cmd.append("--set")
                        cmd.append(str(k) + "=" + str(v))
                res = ctx.run(cmd, mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to install plugin: " + res.stderr)
            actions.append("Installed plugin " + preferred_name)

            if not ctx.check_mode:
                cmd = ["docker", "plugin", "enable"]
                if enable_timeout > 0:
                    cmd.extend(["--timeout", str(enable_timeout)])
                cmd.append(preferred_name)
                res = ctx.run(cmd, mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to enable plugin: " + res.stderr)
            actions.append("Enabled plugin " + preferred_name)
            changed = True
        else:
            # Plugin exists
            enabled = existing_plugin.get("Enabled", False)
            if enabled:
                changed = False
            else:
                if not ctx.check_mode:
                    cmd = ["docker", "plugin", "enable"]
                    if enable_timeout > 0:
                        cmd.extend(["--timeout", str(enable_timeout)])
                    cmd.append(preferred_name)
                    res = ctx.run(cmd, mutates=True, ok_codes=[0])
                    if res.rc != 0:
                        fail("Failed to enable plugin: " + res.stderr)
                actions.append("Enabled plugin " + preferred_name)
                changed = True

    elif state == "disable":
        if existing_plugin == None:
            fail("Plugin not found: Plugin does not exist.")
        else:
            enabled = existing_plugin.get("Enabled", False)
            if not enabled:
                changed = False
            else:
                if not ctx.check_mode:
                    res = ctx.run(
                        ["docker", "plugin", "disable", preferred_name],
                        mutates=True,
                        ok_codes=[0]
                    )
                    if res.rc != 0:
                        fail("Failed to disable plugin: " + res.stderr)
                actions.append("Disabled plugin " + preferred_name)
                changed = True

    else:
        fail("Unsupported state: " + state)

    return {"changed": changed, "msg": " ".join(actions) if actions else "No action required", "actions": actions}
