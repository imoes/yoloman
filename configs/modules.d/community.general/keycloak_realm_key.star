def main(ctx, params):
    # Extract required params
    name = params["name"]
    parent_id = params["parent_id"]
    state = params.get("state", "present")
    force = params.get("force", False)
    provider_id = params.get("provider_id", "rsa")
    config = params.get("config", {})

    # Extract auth params
    auth_url = params["auth_keycloak_url"]
    auth_realm = params.get("auth_realm")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_client_secret = params.get("auth_client_secret")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Build auth headers
    headers = {"User-Agent": http_agent}
    if token != None:
        headers["Authorization"] = "Bearer " + token
    else:
        if not auth_realm or not auth_username or not auth_password:
            fail("authentication requires either token or (auth_realm, auth_username, auth_password)")
        # Get token from Keycloak
        payload = "client_id=" + auth_client_id + "&username=" + auth_username + "&password=" + auth_password + "&grant_type=password"
        if auth_client_secret != None:
            payload = payload + "&client_secret=" + auth_client_secret
        if auth_realm != None:
            payload = payload + "&realm=" + auth_realm

        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded",
             "-d", payload, auth_url.rstrip("/") + "/realms/" + (auth_realm or "master") + "/protocol/openid-connect/token"],
            mutates=False
        )
        if res.rc != 0:
            fail("failed to get auth token: " + res.stderr)
        # Extract access_token from JSON-like response using string operations
        if '"access_token":"' not in res.stdout:
            fail("access_token not found in token response")
        token_start = res.stdout.index('"access_token":"') + len('"access_token":"')
        token_end = res.stdout.index('"', token_start)
        token_val = res.stdout[token_start:token_end]
        headers["Authorization"] = "Bearer " + token_val

    # Prepare config payload (convert snake_case keys to camelCase and wrap in list format)
    config_payload = {}
    for key, val in config.items():
        if key == "active":
            config_payload["active"] = ["true" if val else "false"]
        elif key == "enabled":
            config_payload["enabled"] = ["true" if val else "false"]
        elif key == "priority":
            config_payload["priority"] = [str(val)]
        elif key == "algorithm":
            config_payload["algorithm"] = [val]
        elif key == "private_key":
            pk = val.replace("\\n", "\n")
            config_payload["privateKey"] = [pk]
        elif key == "certificate":
            cert = val.replace("\\n", "\n")
            config_payload["certificate"] = [cert]
        else:
            config_payload[key] = [str(val)]

    # Build component payload
    component = {
        "name": name,
        "parentId": parent_id,
        "providerId": provider_id,
        "providerType": "org.keycloak.keys.KeyProvider",
        "config": config_payload,
    }

    # Probe existing key
    res = ctx.run(
        ["curl", "-s", "-H", "Authorization: " + headers["Authorization"],
         "-H", "Accept: application/json",
         "--max-time", str(connection_timeout),
         "--connect-timeout", str(connection_timeout),
         auth_url.rstrip("/") + "/admin/realms/" + parent_id + "/components?parentId=" + parent_id + "&type=org.keycloak.keys.KeyProvider"],
        mutates=False
    )
    if res.rc != 0:
        fail("failed to list components: " + res.stderr)

    # Parse JSON response manually to find component by name
    keys_json = res.stdout
    key_id = None
    current_config = {}

    # Simple JSON search: locate the component with matching name
    # Look for '"name":"<name>"' and extract id from same object
    name_key = '"name":"' + name + '"'
    idx = keys_json.find(name_key)
    if idx != -1:
        # Search backward to find opening '{' of the object
        obj_start = keys_json.rfind("{", 0, idx)
        # Search forward to find closing '}' after this object
        obj_end = keys_json.find("}", idx)
        if obj_start != -1 and obj_end != -1 and obj_end > obj_start:
            obj_str = keys_json[obj_start:obj_end+1]
            # Extract id
            if '"id":"' in obj_str:
                id_start = obj_str.index('"id":"') + len('"id":"')
                id_end = obj_str.find('"', id_start)
                if id_end != -1:
                    key_id = obj_str[id_start:id_end]
            # Extract config
            if '"config":{' in obj_str:
                cfg_idx = obj_str.index('"config":{')
                cfg_end = obj_str.find("}", cfg_idx)
                cfg_str = obj_str[cfg_idx+len('"config":{'):cfg_end+1]
                # Parse simple key-value pairs
                for k in ["active", "enabled", "priority", "algorithm", "privateKey", "certificate"]:
                    pat = '"' + k + '":'
                    if pat in cfg_str:
                        s = cfg_str.index(pat) + len(pat)
                        # Value format: ["value"]
                        if cfg_str[s:].startswith('["'):
                            val_end = cfg_str.find('"]', s)
                            if val_end != -1:
                                current_config[k] = cfg_str[s+len('["'):val_end]
                        else:
                            val_end = cfg_str.find('"', s)
                            if val_end != -1:
                                current_config[k] = cfg_str[s:val_end]

    # Determine if update is needed (excluding privateKey and certificate for comparison)
    need_update = False
    if key_id != None:
        component["id"] = key_id
        # Compare non-sensitive fields
        for k in ["name", "parentId", "providerId", "providerType"]:
            if component.get(k) != current_config.get(k):
                need_update = True
                break
        # Compare config (except private key and cert)
        if not need_update:
            for k in ["active", "enabled", "priority", "algorithm"]:
                expected = ""
                arr = component["config"].get(k, [])
                if len(arr) > 0:
                    expected = arr[0]
                actual = current_config.get(k, "")
                if expected != actual:
                    need_update = True
                    break

    # Helper to build JSON payload manually (no json module)
    def to_json(d):
        parts = []
        for k, v in d.items():
            if isinstance(v, list):
                inner = ",".join(['"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"' for x in v])
                parts.append('"' + k + '":[' + inner + "]")
            elif isinstance(v, bool):
                parts.append('"' + k + '":' + ('true' if v else 'false'))
            elif isinstance(v, int):
                parts.append('"' + k + '":' + str(v))
            else:
                parts.append('"' + k + '":"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"')
        return "{" + ",".join(parts) + "}"

    # Handle states
    if state == "present":
        if key_id != None:
            if need_update or force:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update realm key " + name}
                res = ctx.run(
                    ["curl", "-s", "-X", "PUT",
                     "-H", "Authorization: " + headers["Authorization"],
                     "-H", "Content-Type: application/json",
                     "-d", to_json(component),
                     "--max-time", str(connection_timeout),
                     "--connect-timeout", str(connection_timeout),
                     auth_url.rstrip("/") + "/admin/realms/" + parent_id + "/components/" + key_id],
                    mutates=True
                )
                if res.rc != 0:
                    fail("failed to update realm key: " + res.stderr)
                return {"changed": True, "msg": "realm key " + name + " updated"}
            else:
                return {"changed": False, "msg": "realm key " + name + " already in sync"}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create realm key " + name}
            res = ctx.run(
                ["curl", "-s", "-X", "POST",
                 "-H", "Authorization: " + headers["Authorization"],
                 "-H", "Content-Type: application/json",
                 "-d", to_json(component),
                 "--max-time", str(connection_timeout),
                 "--connect-timeout", str(connection_timeout),
                 auth_url.rstrip("/") + "/admin/realms/" + parent_id + "/components"],
                mutates=True
            )
            if res.rc != 0:
                fail("failed to create realm key: " + res.stderr)
            return {"changed": True, "msg": "realm key " + name + " created"}
    elif state == "absent":
        if key_id != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete realm key " + name}
            res = ctx.run(
                ["curl", "-s", "-X", "DELETE",
                 "-H", "Authorization: " + headers["Authorization"],
                 "--max-time", str(connection_timeout),
                 "--connect-timeout", str(connection_timeout),
                 auth_url.rstrip("/") + "/admin/realms/" + parent_id + "/components/" + key_id],
                mutates=True
            )
            if res.rc != 0:
                fail("failed to delete realm key: " + res.stderr)
            return {"changed": True, "msg": "realm key " + name + " deleted"}
        else:
            return {"changed": False, "msg": "realm key " + name + " not present"}
