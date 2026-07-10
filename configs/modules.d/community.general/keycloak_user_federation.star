def main(ctx, params):
    # Extract required params with defaults
    state = params.get("state", "present")
    realm = params.get("realm", "master")
    name = params.get("name")
    cid = params.get("id")
    provider_id = params.get("provider_id")
    provider_type = params.get("provider_type", "org.keycloak.storage.UserStorageProvider")
    mappers = params.get("mappers")
    config = params.get("config")

    # Auth params
    auth_url = params["auth_keycloak_url"].rstrip("/")
    auth_realm = params.get("auth_realm", "master")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_client_secret = params.get("auth_client_secret")

    # Build token endpoint URL
    token_url = auth_url + "/realms/" + auth_realm + "/protocol/openid-connect/token"

    # Prepare token POST data
    token_data = "grant_type=password&client_id=" + auth_client_id + "&username=" + auth_username + "&password=" + auth_password
    if auth_client_secret != None:
        token_data = token_data + "&client_secret=" + auth_client_secret

    # Get token
    token_res = ctx.run(
        [
            "curl",
            "-s",
            "-X",
            "POST",
            token_url,
            "-H",
            "Content-Type: application/x-www-form-urlencoded",
            "-d",
            token_data,
        ],
        mutates=False,
    )
    if token_res.rc != 0:
        fail("Failed to get access token: " + token_res.stderr)

    # Parse access token from response
    token = ""
    token_json = token_res.stdout.strip()
    if '"access_token"' in token_json:
        parts = token_json.split('"access_token"')
        if len(parts) > 1:
            token_part = parts[1].strip()
            if token_part.startswith(":") or token_part.startswith('"'):
                token_part = token_part.lstrip(': "')
                if '"' in token_part:
                    token = token_part.split('"')[0]
    if token == "":
        fail("Failed to extract access token")

    # Helper to build URL-encoded query string
    def urlencode(d):
        items = []
        for k, v in sorted(d.items()):
            items.append(str(k) + "=" + str(v))
        return "&".join(items)

    # Helper to make API calls
    def kc_get(path):
        res = ctx.run(
            [
                "curl",
                "-s",
                "-X",
                "GET",
                auth_url + path,
                "-H",
                "Authorization: Bearer " + token,
                "-H",
                "Accept: application/json",
            ],
            mutates=False,
        )
        if res.rc != 0:
            fail("GET " + path + " failed: " + res.stderr)
        return res.stdout

    def kc_post(path, payload):
        # Escape double quotes in payload string
        escaped_payload = payload.replace('"', '\\"')
        res = ctx.run(
            [
                "curl",
                "-s",
                "-X",
                "POST",
                auth_url + path,
                "-H",
                "Authorization: Bearer " + token,
                "-H",
                "Content-Type: application/json",
                "-d",
                escaped_payload,
            ],
            mutates=True,
        )
        if res.rc != 0:
            fail("POST " + path + " failed: " + res.stderr)
        return res.stdout

    def kc_put(path, payload):
        escaped_payload = payload.replace('"', '\\"')
        res = ctx.run(
            [
                "curl",
                "-s",
                "-X",
                "PUT",
                auth_url + path,
                "-H",
                "Authorization: Bearer " + token,
                "-H",
                "Content-Type: application/json",
                "-d",
                escaped_payload,
            ],
            mutates=True,
        )
        if res.rc != 0:
            fail("PUT " + path + " failed: " + res.stderr)
        return res.stdout

    def kc_delete(path):
        res = ctx.run(
            [
                "curl",
                "-s",
                "-X",
                "DELETE",
                auth_url + path,
                "-H",
                "Authorization: Bearer " + token,
            ],
            mutates=True,
        )
        if res.rc != 0:
            fail("DELETE " + path + " failed: " + res.stderr)

    def build_config_json(cfg):
        # Convert flat dict into Keycloak's expected array format
        # e.g. {"enabled": true} -> {"enabled": ["true"]}
        items = []
        for k, v in sorted(cfg.items()):
            if v == None:
                continue
            if type(v) == "bool":
                str_val = "true" if v else "false"
            elif type(v) == "int":
                str_val = str(v)
            else:
                str_val = str(v)
            # Keycloak expects array of strings
            items.append('"' + k + '": ["' + str_val + '"]')
        return "{" + ",".join(items) + "}"

    def build_component_json(name, provider_id, provider_type, config, parent_id):
        cfg_json = build_config_json(config) if config != None else "{}"
        return (
            '{"name":"'
            + name
            + '","providerId":"'
            + provider_id
            + '","providerType":"'
            + provider_type
            + '","config":'
            + cfg_json
            + ',"parentId":"'
            + parent_id
            + '"}'
        )

    # Determine parent_id (realm ID)
    realm_res = kc_get("/admin/realms/" + realm)
    if realm_res == "":
        fail("Realm " + realm + " not found")
    # Extract realm id
    realm_id = ""
    if '"id"' in realm_res:
        parts = realm_res.split('"id"')
        if len(parts) > 1:
            part = parts[1].strip()
            if part.startswith(':'):
                part = part.lstrip(': "')
                if '"' in part:
                    realm_id = part.split('"')[0]

    # Get existing component
    existing_comp = None
    if cid != None:
        comp_res = kc_get("/admin/realms/" + realm + "/components/" + cid)
        if comp_res != "":
            existing_comp = comp_res
    elif name != None:
        # Search by name
        comp_list_res = kc_get("/admin/realms/" + realm + "/components?" + urlencode(dict(type=provider_type, name=name)))
        # Parse JSON list manually
        comp_list = []
        if comp_list_res.startswith("[") and comp_list_res.endswith("]"):
            inner = comp_list_res[1:-1].strip()
            if inner != "":
                # naive split on },{ — works for simple cases
                comps = inner.split("},{")
                for c in comps:
                    if c.count("{") > c.count("}"):
                        c = "{" + c
                    if c.count("}") > c.count("{"):
                        c = c + "}"
                    comp_list.append(c)
        for comp in comp_list:
            if ('"name":"'+name+'"') in comp or ('"name": "'+name+'"') in comp:
                existing_comp = comp
                # Extract id if needed
                if '"id"' in comp:
                    parts = comp.split('"id"')
                    if len(parts) > 1:
                        part = parts[1].strip()
                        if part.startswith(':'):
                            part = part.lstrip(': "')
                            if '"' in part:
                                cid = part.split('"')[0]
                break
        if existing_comp == None and len(comp_list) > 0:
            fail("Multiple components with name " + name + " found")
    else:
        fail("Either 'id' or 'name' must be specified")

    # Get existing mappers if component exists
    existing_mappers = []
    if existing_comp != None and cid != None:
        mappers_res = kc_get("/admin/realms/" + realm + "/components/" + cid + "/subComponents")
        if mappers_res.startswith("[") and mappers_res.endswith("]"):
            inner = mappers_res[1:-1].strip()
            if inner != "":
                mappers_list = inner.split("},{")
                for m in mappers_list:
                    if m.count("{") > m.count("}"):
                        m = "{" + m
                    if m.count("}") > m.count("{"):
                        m = m + "}"
                    existing_mappers.append(m)

    # Build desired component payload
    if state == "present" and (name == None or provider_id == None):
        fail("Both 'name' and 'provider_id' are required when state is present")

    desired_config = {}
    if config != None:
        desired_config = config
    # Ensure boolean/int fields are handled properly
    if "enabled" in desired_config and type(desired_config["enabled"]) == "bool":
        pass
    if "priority" in desired_config and type(desired_config["priority"]) == "int":
        pass
    if "batchSizeForSync" in desired_config and type(desired_config["batchSizeForSync"]) == "int":
        pass

    desired_comp_json = build_component_json(
        name, provider_id, provider_type, desired_config, realm_id
    )

    # Compare existing vs desired
    changed = False
    msg = ""
    if existing_comp == None:
        if state == "absent":
            changed = False
            msg = "User federation does not exist; doing nothing."
        else:
            changed = True
            if ctx.check_mode:
                msg = "would create user federation " + (name if name != None else cid if cid != None else "")
            else:
                create_res = kc_post("/admin/realms/" + realm + "/components", desired_comp_json)
                new_id = ""
                if create_res.startswith("{"):
                    if '"id"' in create_res:
                        parts = create_res.split('"id"')
                        if len(parts) > 1:
                            part = parts[1].strip()
                            if part.startswith(':'):
                                part = part.lstrip(': "')
                                if '"' in part:
                                    new_id = part.split('"')[0]
                if new_id == "":
                    fail("Failed to extract new component ID")
                cid = new_id
                msg = "User federation created with id " + cid
                # Handle mappers
                if mappers != None:
                    if provider_id in ["kerberos", "sssd"]:
                        fail("Cannot configure mappers for " + provider_id + " provider.")
                    for mapper in mappers:
                        mapper_name = mapper.get("name")
                        mapper_id = mapper.get("id")
                        # Check if mapper exists
                        existing_mapper = None
                        if mapper_id != None:
                            mapper_res = kc_get("/admin/realms/" + realm + "/components/" + mapper_id)
                            if mapper_res != "":
                                existing_mapper = mapper_res
                        elif mapper_name != None:
                            found = []
                            for m in existing_mappers:
                                if ('"name":"'+mapper_name+'"') in m or ('"name": "'+mapper_name+'"') in m:
                                    found.append(m)
                            if len(found) > 1:
                                fail("Found multiple mappers with name " + mapper_name)
                            if len(found) == 1:
                                existing_mapper = found[0]
                        # Build desired mapper
                        mapper_config = mapper.get("config", {})
                        mapper_cfg_json = build_config_json(mapper_config)
                        mapper_json = '{"name":"' + (mapper_name or "") + '","providerId":"' + (mapper.get("provider_id") or "") + '","providerType":"' + (mapper.get("provider_type") or "org.keycloak.storage.ldap.mappers.LDAPStorageMapper") + '","config":' + mapper_cfg_json + ',"parentId":"' + cid + '"}'
                        if existing_mapper == None:
                            if ctx.check_mode:
                                msg = msg + "; would create mapper " + (mapper_name or "")
                            else:
                                create_res = kc_post("/admin/realms/" + realm + "/components", mapper_json)
                        else:
                            # Update if different
                            if mapper_json != existing_mapper:
                                if ctx.check_mode:
                                    msg = msg + "; would update mapper " + (mapper_name or "")
                                else:
                                    mapper_id_found = ""
                                    if '"id"' in existing_mapper:
                                        parts = existing_mapper.split('"id"')
                                        if len(parts) > 1:
                                            part = parts[1].strip()
                                            if part.startswith(':'):
                                                part = part.lstrip(': "')
                                                if '"' in part:
                                                    mapper_id_found = part.split('"')[0]
                                    if mapper_id_found != "":
                                        kc_put("/admin/realms/" + realm + "/components/" + mapper_id_found, mapper_json)
    else:
        # Component exists
        if state == "absent":
            changed = True
            if ctx.check_mode:
                msg = "would delete user federation " + (cid if cid != None else name)
            else:
                kc_delete("/admin/realms/" + realm + "/components/" + cid)
                msg = "User federation " + (cid if cid != None else name) + " deleted"
        else:
            # Compare configs
            # Extract config from existing_comp
            existing_config = {}
            if '"config"' in existing_comp:
                # Naive extraction of config section
                cfg_start = existing_comp.find('"config":{')
                if cfg_start != -1:
                    cfg_str = existing_comp[cfg_start + len('"config":{'):]
                    brace_count = 1
                    i = 0
                    while i < len(cfg_str) and brace_count > 0:
                        if cfg_str[i] == "{":
                            brace_count += 1
                        elif cfg_str[i] == "}":
                            brace_count -= 1
                        i += 1
                    cfg_end = i - 1
                    cfg_json_str = cfg_str[:cfg_end]
                    # Parse key-value pairs — simplified
                    for line in cfg_json_str.split(","):
                        line = line.strip()
                        if ':' in line and line.count('"') >= 4:
                            kv = line.split(":")
                            if len(kv) >= 2:
                                key = kv[0].strip().strip('"')
                                val_part = ":".join(kv[1:]).strip()
                                if val_part.startswith('["') and val_part.endswith('"]'):
                                    inner = val_part[2:-2]
                                    existing_config[key] = inner
            # Build desired config in same format
            desired_config_str = build_config_json(desired_config)
            # Compare — basic string diff
            if desired_config_str != '{"' + '","'.join([k + '":["' + str(v) + '"]' for k,v in sorted(desired_config.items())]) + '"}' and False:
                # We need to normalize both sides — use a better compare
                pass
            # Simplified comparison: convert both to sorted list of (key, value)
            existing_items = []
            for k, v in existing_config.items():
                existing_items.append((k, v))
            desired_items = []
            for k, v in desired_config.items():
                desired_items.append((k, str(v)))
            existing_items.sort(key=lambda x: x[0])
            desired_items.sort(key=lambda x: x[0])

            # Compare mappers
            desired_mappers = []
            if mappers != None:
                if provider_id in ["kerberos", "sssd"]:
                    fail("Cannot configure mappers for " + provider_id + " provider.")
                for mapper in mappers:
                    mapper_name = mapper.get("name")
                    mapper_id = mapper.get("id")
                    if mapper_id == None and mapper_name == None:
                        fail("Either `name` or `id` must be specified for each mapper")
                    # Find existing mapper
                    existing_mapper = None
                    for m in existing_mappers:
                        if ('"name":"'+mapper_name+'"') in m or ('"name": "'+mapper_name+'"') in m:
                            if '"id"' in m:
                                parts = m.split('"id"')
                                if len(parts) > 1:
                                    part = parts[1].strip()
                                    if part.startswith(':'):
                                        part = part.lstrip(': "')
                                        if '"' in part:
                                            m_id = part.split('"')[0]
                                            if mapper_id == None or mapper_id == m_id:
                                                existing_mapper = m
                                                break
                    # Build desired mapper JSON
                    mapper_cfg_json = build_config_json(mapper.get("config", {}))
                    desired_mapper = (
                        '{"name":"' + (mapper_name or "") + '","providerId":"' + (mapper.get("provider_id") or "") + '","providerType":"' + (mapper.get("provider_type") or "org.keycloak.storage.ldap.mappers.LDAPStorageMapper") + '","config":' + mapper_cfg_json + ',"parentId":"' + cid + '"}'
                    )
                    if existing_mapper != None:
                        if desired_mapper != existing_mapper:
                            changed = True
                            if not ctx.check_mode:
                                mapper_id_found = ""
                                if '"id"' in existing_mapper:
                                    parts = existing_mapper.split('"id"')
                                    if len(parts) > 1:
                                        part = parts[1].strip()
                                        if part.startswith(':'):
                                            part = part.lstrip(': "')
                                            if '"' in part:
                                                mapper_id_found = part.split('"')[0]
                                if mapper_id_found != "":
                                    kc_put("/admin/realms/" + realm + "/components/" + mapper_id_found, desired_mapper)
                    else:
                        changed = True
                        if not ctx.check_mode:
                            kc_post("/admin/realms/" + realm + "/components", desired_mapper)

            # Compare top-level component
            # Extract fields from existing_comp for comparison
            existing_name = ""
            if '"name":"'+name+'"' in existing_comp or '"name": "'+name+'"' in existing_comp:
                existing_name = name
            existing_provider_id = ""
            if '"providerId":"'+provider_id+'"' in existing_comp or '"providerId": "'+provider_id+'"' in existing_comp:
                existing_provider_id = provider_id

            if existing_name != name or existing_provider_id != provider_id:
                changed = True
            elif existing_config != desired_config:
                changed = True

            if not changed:
                msg = "No changes required to user federation " + (cid if cid != None else name) + "."
            else:
                msg = "would update" if ctx.check_mode else "updated"
                if not ctx.check_mode:
                    # Perform update
                    kc_put("/admin/realms/" + realm + "/components/" + cid, desired_comp_json)
                msg = "User federation " + (cid if cid != None else name) + " " + msg

    return {"changed": changed, "msg": msg}
