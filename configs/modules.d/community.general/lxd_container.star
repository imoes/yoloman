def main(ctx, params):
    name = params["name"]
    state = params.get("state", "started")
    project = params.get("project")
    architecture = params.get("architecture")
    config = params.get("config", {})
    devices = params.get("devices", {})
    ephemeral = params.get("ephemeral")
    profiles = params.get("profiles", [])
    source = params.get("source")
    type_ = params.get("type", "container")
    target = params.get("target")
    timeout = params.get("timeout", 30)
    wait_for_ipv4 = params.get("wait_for_ipv4_addresses", False)
    force_stop = params.get("force_stop", False)
    ignore_volatile = params.get("ignore_volatile_options", False)
    trust_password = params.get("trust_password")
    client_key = params.get("client_key")
    client_cert = params.get("client_cert")
    url = params.get("url", "unix:/var/lib/lxd/unix.socket")
    snap_url = params.get("snap_url", "unix:/var/snap/lxd/common/lxd/unix.socket")

    # Determine LXD endpoint URL
    if url != "unix:/var/lib/lxd/unix.socket":
        endpoint_url = url
    elif ctx.file_exists(snap_url.replace("unix:", "")):
        endpoint_url = snap_url
    else:
        endpoint_url = url

    # Determine paths for client key and cert
    home = ctx.facts().get("home", "")
    if client_key == None:
        client_key = home + "/.config/lxc/client.key"
    if client_cert == None:
        client_cert = home + "/.config/lxc/client.crt"

    # Validate type
    if type_ not in ["container", "virtual-machine"]:
        fail("unsupported type: " + type_)

    # Build API endpoint path
    if type_ == "container":
        api_endpoint = "/1.0/containers"
    else:
        api_endpoint = "/1.0/virtual-machines"

    # Auth helper: authenticate if trust_password provided
    if trust_password != None:
        auth_resp = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""), 
                             "-X", "POST", "-d", '{"password":"%s"}' % trust_password, 
                             endpoint_url + "/1.0/operations"], mutates=False)
        if auth_resp.rc != 0:
            fail("authentication failed")

    # Helper to build URL with project and target
    def build_url(path, add_params=True):
        base = endpoint_url.replace("unix:", "http+unix:/") + path
        if not add_params:
            return base
        parts = []
        if project != None:
            parts.append("project=" + project)
        if target != None:
            parts.append("target=" + target)
        if len(parts) > 0:
            return base + "?" + "&".join(parts)
        return base

    # Get instance state and metadata
    def get_instance():
        url = build_url(api_endpoint + "/" + name)
        res = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""),
                       "-X", "GET", url], mutates=False)
        if res.rc == 404:
            return None
        if res.rc != 0:
            fail("failed to get instance: " + res.stderr)
        return res.stdout

    def get_instance_state():
        url = build_url(api_endpoint + "/" + name + "/state")
        res = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""),
                       "-X", "GET", url], mutates=False)
        if res.rc == 404:
            return None
        if res.rc != 0:
            fail("failed to get state: " + res.stderr)
        return res.stdout

    def parse_json(s):
        # Very minimal JSON parser for expected keys only
        s = s.strip()
        if s.startswith("{"):
            s = s[1:]
        if s.endswith("}"):
            s = s[:-1]
        result = {}
        # Split top-level key-value pairs by comma, respecting quoted strings
        i = 0
        current_key = ""
        current_val = ""
        in_key = True
        in_str = False
        escape = False
        brace_count = 0
        for c in s:
            if escape:
                if in_key:
                    current_key += c
                else:
                    current_val += c
                escape = False
                continue
            if c == "\\" and in_str:
                escape = True
                continue
            if c == '"' and not escape:
                in_str = not in_str
                continue
            if not in_str:
                if c == '{':
                    brace_count += 1
                elif c == '}':
                    brace_count -= 1
            if not in_str and brace_count == 0 and c == ',':
                if len(current_key) > 0:
                    result[current_key.strip()] = current_val.strip()
                current_key = ""
                current_val = ""
                in_key = True
            elif c == ':' and not in_str and in_key:
                in_key = False
            else:
                if in_key:
                    current_key += c
                else:
                    current_val += c
        if len(current_key) > 0:
            result[current_key.strip()] = current_val.strip()
        return result

    def extract_status(metadata_str):
        metadata = parse_json(metadata_str)
        if metadata == None or metadata.get("status") == None:
            return "absent"
        status_map = {
            '"Running"': "started",
            '"Stopped"': "stopped",
            '"Frozen"': "frozen"
        }
        return status_map.get(metadata["status"], "absent")

    # Get current state
    instance_json = get_instance()
    if instance_json == None:
        old_state = "absent"
        old_metadata = {}
    else:
        old_state = extract_status(instance_json)
        old_metadata = parse_json(instance_json)

    # Filter volatile keys from old config if ignore_volatile is set
    def filter_volatile(d):
        if d == {}:
            return d
        result = {}
        for k, v in d.items():
            if k.startswith("volatile.") and ignore_volatile:
                continue
            result[k] = v
        return result

    old_config = filter_volatile(old_metadata.get("config", {}))
    old_devices = old_metadata.get("devices", {})
    old_profiles = old_metadata.get("profiles", [])
    old_architecture = old_metadata.get("architecture", "")
    old_ephemeral = old_metadata.get("ephemeral", False)

    # Helper to perform config change check
    def needs_config_change():
        # architecture
        if architecture != None and architecture != old_architecture:
            return True
        # config
        for k, v in config.items():
            if old_config.get(k) != v:
                return True
        # devices
        for k, v in devices.items():
            if old_devices.get(k) != v:
                return True
        # profiles — compare lists (order-insensitive)
        old_profiles_sorted = sorted(old_profiles)
        new_profiles_sorted = sorted(profiles)
        if old_profiles_sorted != new_profiles_sorted:
            return True
        # ephemeral
        if ephemeral != None and old_ephemeral != None and str(ephemeral) != str(old_ephemeral):
            return True
        return False

    # Helper to send PUT request to update instance config
    def apply_config():
        body = {}
        body["config"] = old_config.copy()
        for k, v in config.items():
            body["config"][k] = v
        body["devices"] = old_devices.copy()
        for k, v in devices.items():
            body["devices"][k] = v
        if profiles != []:
            body["profiles"] = profiles
        if architecture != None:
            body["architecture"] = architecture
        if ephemeral != None:
            body["ephemeral"] = ephemeral

        # Build request body JSON manually
        def to_json(obj):
            if type(obj) == "bool":
                return "true" if obj else "false"
            if type(obj) == "int" or type(obj) == "float":
                return str(obj)
            if type(obj) == "string":
                # Escape quotes and backslashes
                s = obj.replace("\\", "\\\\").replace('"', '\\"')
                return '"' + s + '"'
            if type(obj) == "list":
                items = [to_json(x) for x in obj]
                return "[" + ",".join(items) + "]"
            if type(obj) == "dict":
                pairs = []
                for k, v in obj.items():
                    pairs.append('"' + k + '":' + to_json(v))
                return "{" + ",".join(pairs) + "}"
            if obj == None:
                return "null"
            return '"' + str(obj) + '"'

        body_json_str = to_json(body)
        url = build_url(api_endpoint + "/" + name)
        res = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""),
                       "-X", "PUT", "-d", body_json_str, url], mutates=True)
        if res.rc != 0:
            fail("failed to apply config: " + res.stderr)

    # Helper to change instance state (start/stop/restart/freeze/unfreeze)
    def change_state(action, force=False):
        body = '{"action":"%s","timeout":%d}' % (action, timeout)
        if force:
            body = '{"action":"%s","timeout":%d,"force":true}' % (action, timeout)
        url = build_url(api_endpoint + "/" + name + "/state")
        res = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""),
                       "-X", "PUT", "-d", body, url], mutates=True)
        if res.rc != 0:
            fail("failed to %s instance: %s" % (action, res.stderr))

    # Helper to get IPv4 addresses
    def get_ipv4_addresses():
        state_json = get_instance_state()
        if state_json == None:
            return {}
        state_dict = parse_json(state_json)
        network = state_dict.get("network", {})
        result = {}
        for dev_name, dev_data_str in network.items():
            dev_data = parse_json(dev_data_str)
            addresses = dev_data.get("addresses", [])
            ipv4_list = []
            for addr_data in addresses:
                addr = parse_json(addr_data)
                if addr.get("family") == '"inet"':
                    ipv4_list.append(addr.get("address", "").replace('"', ''))
            if len(ipv4_list) > 0:
                result[dev_name.replace('"', '')] = ipv4_list
        return result

    # Wait for IPv4 addresses (if needed)
    def wait_for_ipv4():
        due = ctx.time() + timeout
        while ctx.time() < due:
            addresses = get_ipv4_addresses()
            ok = True
            for dev, addrs in addresses.items():
                if len(addrs) == 0:
                    ok = False
                    break
            if ok or ctx.check_mode:
                return addresses
            # Sleep 1s — use built-in time.sleep equivalent via curl trick
            ctx.run(["sleep", "1"], mutates=False)
        fail("timeout waiting for IPv4 addresses")

    # Actions
    actions = []
    changed = False

    if state == "absent":
        if old_state != "absent":
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete container"}
            # Stop/freeze if needed before delete
            if old_state == "frozen":
                change_state("unfreeze")
            if old_state != "stopped":
                change_state("stop", force=force_stop)
            # Delete
            url = build_url(api_endpoint + "/" + name)
            res = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""),
                           "-X", "DELETE", url], mutates=True)
            if res.rc != 0:
                fail("failed to delete: " + res.stderr)
            actions.append("delete")
            changed = True
        return {"changed": changed, "msg": "container absent" if not changed else "container deleted"}

    elif state == "started":
        if old_state == "absent":
            if ctx.check_mode:
                return {"changed": True, "msg": "would create and start container"}
            # Create
            create_body = {"name": name}
            if architecture != None:
                create_body["architecture"] = architecture
            if config != {}:
                create_body["config"] = config
            if devices != {}:
                create_body["devices"] = devices
            if profiles != []:
                create_body["profiles"] = profiles
            if ephemeral != None:
                create_body["ephemeral"] = ephemeral
            if source != None:
                create_body["source"] = source

            def to_json(obj):
                if type(obj) == "bool":
                    return "true" if obj else "false"
                if type(obj) == "int" or type(obj) == "float":
                    return str(obj)
                if type(obj) == "string":
                    s = obj.replace("\\", "\\\\").replace('"', '\\"')
                    return '"' + s + '"'
                if type(obj) == "list":
                    items = [to_json(x) for x in obj]
                    return "[" + ",".join(items) + "]"
                if type(obj) == "dict":
                    pairs = []
                    for k, v in obj.items():
                        pairs.append('"' + k + '":' + to_json(v))
                    return "{" + ",".join(pairs) + "}"
                if obj == None:
                    return "null"
                return '"' + str(obj) + '"'

            create_json_str = to_json(create_body)
            url = build_url(api_endpoint)
            res = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""),
                           "-X", "POST", "-d", create_json_str, url], mutates=True)
            if res.rc != 0:
                fail("failed to create: " + res.stderr)
            actions.append("create")
            # Start
            change_state("start")
            actions.append("start")
            changed = True
        else:
            if old_state == "frozen":
                change_state("unfreeze")
                actions.append("unfreeze")
                changed = True
            elif old_state == "stopped":
                change_state("start")
                actions.append("start")
                changed = True
            # Config change?
            if needs_config_change():
                apply_config()
                actions.append("apply_config")
                changed = True
        if wait_for_ipv4:
            addresses = wait_for_ipv4()
            if ctx.check_mode:
                return {"changed": True, "msg": "would wait for IPv4 and return addresses", "addresses": addresses}
            return {"changed": changed, "msg": "container started", "addresses": addresses}
        return {"changed": changed, "msg": "container started"}

    elif state == "stopped":
        if old_state == "absent":
            if ctx.check_mode:
                return {"changed": True, "msg": "would create and stop container"}
            # Create
            create_body = {"name": name}
            if architecture != None:
                create_body["architecture"] = architecture
            if config != {}:
                create_body["config"] = config
            if devices != {}:
                create_body["devices"] = devices
            if profiles != []:
                create_body["profiles"] = profiles
            if ephemeral != None:
                create_body["ephemeral"] = ephemeral
            if source != None:
                create_body["source"] = source

            def to_json(obj):
                if type(obj) == "bool":
                    return "true" if obj else "false"
                if type(obj) == "int" or type(obj) == "float":
                    return str(obj)
                if type(obj) == "string":
                    s = obj.replace("\\", "\\\\").replace('"', '\\"')
                    return '"' + s + '"'
                if type(obj) == "list":
                    items = [to_json(x) for x in obj]
                    return "[" + ",".join(items) + "]"
                if type(obj) == "dict":
                    pairs = []
                    for k, v in obj.items():
                        pairs.append('"' + k + '":' + to_json(v))
                    return "{" + ",".join(pairs) + "}"
                if obj == None:
                    return "null"
                return '"' + str(obj) + '"'

            create_json_str = to_json(create_body)
            url = build_url(api_endpoint)
            res = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""),
                           "-X", "POST", "-d", create_json_str, url], mutates=True)
            if res.rc != 0:
                fail("failed to create: " + res.stderr)
            actions.append("create")
            # Stop if needed
            if old_state != "stopped":
                change_state("stop", force=force_stop)
                actions.append("stop")
                changed = True
        else:
            if old_state == "stopped":
                if needs_config_change():
                    change_state("start")
                    actions.append("start")
                    apply_config()
                    actions.append("apply_config")
                    change_state("stop", force=force_stop)
                    actions.append("stop")
                    changed = True
            else:
                if old_state == "frozen":
                    change_state("unfreeze")
                    actions.append("unfreeze")
                    changed = True
                if needs_config_change():
                    apply_config()
                    actions.append("apply_config")
                    changed = True
                change_state("stop", force=force_stop)
                actions.append("stop")
                changed = True
        return {"changed": changed, "msg": "container stopped"}

    elif state == "restarted":
        if old_state == "absent":
            if ctx.check_mode:
                return {"changed": True, "msg": "would create and restart container"}
            create_body = {"name": name}
            if architecture != None:
                create_body["architecture"] = architecture
            if config != {}:
                create_body["config"] = config
            if devices != {}:
                create_body["devices"] = devices
            if profiles != []:
                create_body["profiles"] = profiles
            if ephemeral != None:
                create_body["ephemeral"] = ephemeral
            if source != None:
                create_body["source"] = source

            def to_json(obj):
                if type(obj) == "bool":
                    return "true" if obj else "false"
                if type(obj) == "int" or type(obj) == "float":
                    return str(obj)
                if type(obj) == "string":
                    s = obj.replace("\\", "\\\\").replace('"', '\\"')
                    return '"' + s + '"'
                if type(obj) == "list":
                    items = [to_json(x) for x in obj]
                    return "[" + ",".join(items) + "]"
                if type(obj) == "dict":
                    pairs = []
                    for k, v in obj.items():
                        pairs.append('"' + k + '":' + to_json(v))
                    return "{" + ",".join(pairs) + "}"
                if obj == None:
                    return "null"
                return '"' + str(obj) + '"'

            create_json_str = to_json(create_body)
            url = build_url(api_endpoint)
            res = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""),
                           "-X", "POST", "-d", create_json_str, url], mutates=True)
            if res.rc != 0:
                fail("failed to create: " + res.stderr)
            actions.append("create")
            change_state("start")
            actions.append("start")
            changed = True
        else:
            if old_state == "frozen":
                change_state("unfreeze")
                actions.append("unfreeze")
                changed = True
            if needs_config_change():
                apply_config()
                actions.append("apply_config")
                changed = True
            change_state("restart", force=force_stop)
            actions.append("restart")
            changed = True
        if wait_for_ipv4:
            addresses = wait_for_ipv4()
            if ctx.check_mode:
                return {"changed": True, "msg": "would wait for IPv4 and restart", "addresses": addresses}
            return {"changed": changed, "msg": "container restarted", "addresses": addresses}
        return {"changed": changed, "msg": "container restarted"}

    elif state == "frozen":
        if old_state == "absent":
            if ctx.check_mode:
                return {"changed": True, "msg": "would create, start, and freeze container"}
            create_body = {"name": name}
            if architecture != None:
                create_body["architecture"] = architecture
            if config != {}:
                create_body["config"] = config
            if devices != {}:
                create_body["devices"] = devices
            if profiles != []:
                create_body["profiles"] = profiles
            if ephemeral != None:
                create_body["ephemeral"] = ephemeral
            if source != None:
                create_body["source"] = source

            def to_json(obj):
                if type(obj) == "bool":
                    return "true" if obj else "false"
                if type(obj) == "int" or type(obj) == "float":
                    return str(obj)
                if type(obj) == "string":
                    s = obj.replace("\\", "\\\\").replace('"', '\\"')
                    return '"' + s + '"'
                if type(obj) == "list":
                    items = [to_json(x) for x in obj]
                    return "[" + ",".join(items) + "]"
                if type(obj) == "dict":
                    pairs = []
                    for k, v in obj.items():
                        pairs.append('"' + k + '":' + to_json(v))
                    return "{" + ",".join(pairs) + "}"
                if obj == None:
                    return "null"
                return '"' + str(obj) + '"'

            create_json_str = to_json(create_body)
            url = build_url(api_endpoint)
            res = ctx.run(["curl", "-s", "-k", "--unix-socket", endpoint_url.replace("unix:", ""),
                           "-X", "POST", "-d", create_json_str, url], mutates=True)
            if res.rc != 0:
                fail("failed to create: " + res.stderr)
            actions.append("create")
            change_state("start")
            actions.append("start")
            changed = True
        else:
            if old_state == "stopped":
                change_state("start")
                actions.append("start")
                changed = True
            if needs_config_change():
                apply_config()
                actions.append("apply_config")
                changed = True
            change_state("freeze")
            actions.append("freeze")
            changed = True
        return {"changed": changed, "msg": "container frozen"}

    else:
        fail("unsupported state: " + state)
