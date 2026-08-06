def main(ctx, params):
    host = params["host"]
    state = params.get("state", "present")
    user = params.get("user")
    group = params.get("group")
    ssh_config_file = params.get("ssh_config_file")
    identity_file = params.get("identity_file")
    hostname = params.get("hostname")
    port = params.get("port")
    remote_user = params.get("remote_user")
    identities_only = params.get("identities_only")
    user_known_hosts_file = params.get("user_known_hosts_file")
    strict_host_key_checking = params.get("strict_host_key_checking")
    proxycommand = params.get("proxycommand")
    proxyjump = params.get("proxyjump")
    host_key_algorithms = params.get("host_key_algorithms")
    forward_agent = params.get("forward_agent")
    add_keys_to_agent = params.get("add_keys_to_agent")
    controlmaster = params.get("controlmaster")
    controlpath = params.get("controlpath")
    controlpersist = params.get("controlpersist")

    # Determine config file path
    if ssh_config_file == None and user == None:
        config_path = "/etc/ssh/ssh_config"
    elif ssh_config_file != None:
        config_path = ssh_config_file
    elif user != None:
        config_path = "~/.ssh/config"
    else:
        fail("Cannot determine ssh_config path")

    # Expand ~ in path
    if config_path.startswith("~"):
        home = ctx.facts().get("home", "/root")
        config_path = home + config_path[1:]

    # Check identity file path relative to config directory if config exists
    if identity_file != None and ctx.file_exists(config_path):
        config_dir = config_path.rsplit("/", 1)[0]
        identity_file = config_dir + "/" + identity_file
        if not ctx.file_exists(identity_file):
            fail("IdentityFile %s does not exist" % identity_file)

    # Read current config content
    current_content = ""
    if ctx.file_exists(config_path):
        current_content = ctx.file_read(config_path)

    # Parse config into hosts dict
    hosts = {}
    current_host = None
    for line in current_content.split("\n"):
        stripped = line.strip()
        if stripped == "":
            continue
        if stripped.startswith("#"):
            continue
        if stripped.startswith("Host "):
            current_host = stripped[5:].strip()
            hosts[current_host] = {}
        elif current_host != None and stripped.find("=") != -1:
            key, value = stripped.split("=", 1)
            key = key.strip().lower()
            value = value.strip()
            if key in hosts[current_host]:
                if type(hosts[current_host][key]) == "list":
                    hosts[current_host][key].append(value)
                else:
                    hosts[current_host][key] = [hosts[current_host][key], value]
            else:
                hosts[current_host][key] = value
        elif current_host != None and stripped.find(" ") != -1:
            key, value = stripped.split(" ", 1)
            key = key.strip().lower()
            value = value.strip()
            if key in hosts[current_host]:
                if type(hosts[current_host][key]) == "list":
                    hosts[current_host][key].append(value)
                else:
                    hosts[current_host][key] = [hosts[current_host][key], value]
            else:
                hosts[current_host][key] = value

    # Normalize bools
    def _bool_val(v):
        if v == "yes" or v == "true":
            return "yes"
        if v == "no" or v == "false":
            return "no"
        return None

    # Build desired host entry
    desired = {}
    if hostname != None:
        desired["hostname"] = hostname
    if port != None:
        desired["port"] = port
    if remote_user != None:
        desired["user"] = remote_user

    if identity_file != None:
        desired["identityfile"] = identity_file

    if identities_only != None:
        desired["identitiesonly"] = "yes" if identities_only else "no"

    if user_known_hosts_file != None:
        desired["userknownhostsfile"] = user_known_hosts_file

    if strict_host_key_checking != None:
        desired["stricthostkeychecking"] = strict_host_key_checking

    if proxycommand != None:
        desired["proxycommand"] = proxycommand

    if proxyjump != None:
        desired["proxyjump"] = proxyjump

    if host_key_algorithms != None:
        desired["hostkeyalgorithms"] = host_key_algorithms

    if forward_agent != None:
        desired["forwardagent"] = "yes" if forward_agent else "no"

    if add_keys_to_agent != None:
        desired["addkeystoagent"] = "yes" if add_keys_to_agent else "no"

    if controlmaster != None:
        desired["controlmaster"] = controlmaster

    if controlpath != None:
        desired["controlpath"] = controlpath

    if controlpersist != None:
        desired["controlpersist"] = controlpersist

    # Determine if host exists and what changes are needed
    changed = False
    hosts_added = []
    hosts_removed = []
    hosts_changed = []
    hosts_change_diff = []

    if state == "absent":
        if host in hosts:
            changed = True
            hosts_removed.append(host)
            hosts.pop(host)
    elif state == "present":
        if host not in hosts:
            # New host
            hosts[host] = desired
            changed = True
            hosts_added.append(host)
        else:
            # Check for changes
            current = hosts[host]
            new_options = {}
            for key in desired:
                if key in current:
                    if type(current[key]) == "list":
                        if sorted(desired[key]) != sorted(current[key]):
                            new_options[key] = desired[key]
                    elif str(current[key]) != str(desired[key]):
                        new_options[key] = desired[key]
                else:
                    new_options[key] = desired[key]

            # Check for extra keys to remove
            for key in current:
                if key not in desired:
                    new_options[key] = None

            # If any changes needed
            if len(new_options) > 0:
                # Build new options dict without removed keys
                final = dict(current)
                for key, val in new_options.items():
                    if val == None:
                        final.pop(key, None)
                    else:
                        final[key] = val
                hosts[host] = final
                changed = True
                hosts_changed.append(host)
                hosts_change_diff.append({
                    host: {
                        "old": current,
                        "new": final,
                    }
                })

    # Check mode
    if ctx.check_mode:
        if changed:
            return {
                "changed": True,
                "msg": "Configuration would be updated",
                "hosts_added": hosts_added,
                "hosts_removed": hosts_removed,
                "hosts_changed": hosts_changed,
                "hosts_change_diff": hosts_change_diff,
            }
        return {"changed": False, "msg": "Configuration is up to date"}

    # Write config if changed
    if changed:
        # Build new content
        lines = []
        for h in sorted(hosts.keys()):
            lines.append("Host " + h)
            opts = hosts[h]
            for k in sorted(opts.keys()):
                v = opts[k]
                if type(v) == "list":
                    for item in v:
                        lines.append("    " + k + " " + str(item))
                else:
                    lines.append("    " + k + " " + str(v))
            lines.append("")

        new_content = "\n".join(lines)
        if new_content != current_content:
            ctx.file_write(config_path, new_content)

            # Set permissions
            if user != None or group != None:
                ctx.run(["chmod", "0600", config_path])
            else:
                ctx.run(["chmod", "0644", config_path])

            if user != None:
                ctx.run(["chown", user, config_path])
            elif group != None:
                ctx.run(["chgrp", group, config_path])

    return {
        "changed": changed,
        "msg": "Configuration updated" if changed else "Configuration is up to date",
        "hosts_added": hosts_added,
        "hosts_removed": hosts_removed,
        "hosts_changed": hosts_changed,
        "hosts_change_diff": hosts_change_diff,
    }
