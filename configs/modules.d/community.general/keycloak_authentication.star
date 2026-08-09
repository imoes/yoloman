def main(ctx, params):
    alias = params["alias"]
    realm = params["realm"]
    state = params.get("state", "present")
    force = params.get("force", False)
    copy_from = params.get("copyFrom")
    provider_id = params.get("providerId")
    description = params.get("description")
    auth_execs = params.get("authenticationExecutions") or []
    timeout = params.get("connection_timeout", 10)
    validate_certs = params.get("validate_certs", True)
    http_agent = params.get("http_agent", "Ansible")

    auth_url = params.get("auth_keycloak_url")
    if not auth_url:
        fail("auth_keycloak_url is required")

    # Build authorization header
    token = params.get("token")
    if token:
        auth_header = "Bearer " + token
    else:
        username = params.get("auth_username")
        password = params.get("auth_password")
        realm_auth = params.get("auth_realm")
        client_id = params.get("auth_client_id", "admin-cli")
        client_secret = params.get("auth_client_secret")
        if not (username and password and realm_auth):
            fail("auth_username, auth_password, and auth_realm are required when token is not provided")
        # Get token via password grant
        body = "grant_type=password&client_id=" + client_id + "&username=" + username + "&password=" + password
        if client_secret:
            # Simple base64 without import (hardcoded for admin-cli:admin-cli)
            # For generic case, we'll use a minimal approach: use curl to handle auth
            # We'll delegate auth header construction to curl
            auth_header = ""
        else:
            auth_header = ""

        # Use curl to get token
        if client_secret:
            res = ctx.run([
                "curl", "-s", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded",
                "--data-urlencode", "client_id=" + client_id,
                "--data-urlencode", "client_secret=" + client_secret,
                "--data-urlencode", "grant_type=password",
                "--data-urlencode", "username=" + username,
                "--data-urlencode", "password=" + password,
                auth_url + "/realms/" + realm_auth + "/protocol/openid-connect/token",
                "--connect-timeout", str(timeout), "--max-time", str(timeout)
            ])
        else:
            res = ctx.run([
                "curl", "-s", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded",
                "--data-urlencode", "client_id=" + client_id,
                "--data-urlencode", "grant_type=password",
                "--data-urlencode", "username=" + username,
                "--data-urlencode", "password=" + password,
                auth_url + "/realms/" + realm_auth + "/protocol/openid-connect/token",
                "--connect-timeout", str(timeout), "--max-time", str(timeout)
            ])
        if res.rc != 0:
            fail("Failed to obtain access token: " + res.stderr)
        # Parse token from JSON response manually
        data = res.stdout.strip()
        token_val = ""
        # Find access_token in JSON
        i = 0
        while i < len(data):
            if data[i:i+14] == '"access_token"':
                j = i + 14
                while j < len(data) and data[j] not in ['"', ':']:
                    j += 1
                if j < len(data) and data[j] == ':':
                    j += 1
                    while j < len(data) and data[j] in [' ', '\t', '\n', '"']:
                        j += 1
                    if j < len(data) and data[j] == '"':
                        j += 1
                        start = j
                        while j < len(data) and data[j] != '"':
                            j += 1
                        token_val = data[start:j]
                        break
            i += 1
        if not token_val:
            fail("Could not parse access token from response")
        auth_header = "Bearer " + token_val

    # Build headers for API calls
    headers = [
        "-H", "Authorization: " + auth_header,
        "-H", "Content-Type: application/json",
        "-H", "User-Agent: " + http_agent
    ]
    if not validate_certs:
        headers += ["-k"]

    # Helper to call Keycloak API
    def kc_get(path):
        res = ctx.run([
            "curl", "-s", "-X", "GET",
        ] + headers + [
            auth_url + "/admin/realms/" + realm + path,
            "--connect-timeout", str(timeout), "--max-time", str(timeout)
        ])
        if res.rc == 404:
            return None
        if res.rc != 0:
            fail("Keycloak GET error: " + res.stderr)
        return res.stdout

    def kc_post(path, data):
        res = ctx.run([
            "curl", "-s", "-X", "POST",
        ] + headers + [
            "-d", data, auth_url + "/admin/realms/" + realm + path,
            "--connect-timeout", str(timeout), "--max-time", str(timeout)
        ])
        if res.rc != 0 and res.rc != 201:
            fail("Keycloak POST error: " + res.stderr)
        return res.rc == 201

    def kc_put(path, data):
        res = ctx.run([
            "curl", "-s", "-X", "PUT",
        ] + headers + [
            "-d", data, auth_url + "/admin/realms/" + realm + path,
            "--connect-timeout", str(timeout), "--max-time", str(timeout)
        ])
        if res.rc != 0 and res.rc != 204:
            fail("Keycloak PUT error: " + res.stderr)

    def kc_delete(path):
        res = ctx.run([
            "curl", "-s", "-X", "DELETE",
        ] + headers + [
            auth_url + "/admin/realms/" + realm + path,
            "--connect-timeout", str(timeout), "--max-time", str(timeout)
        ])
        if res.rc != 0 and res.rc != 204:
            fail("Keycloak DELETE error: " + res.stderr)

    # Fetch existing flow
    existing = kc_get("/authentication/flows?alias=" + alias)
    auth_repr = None
    if existing:
        # Very basic parse for JSON array and object
        # Look for object with matching alias
        # Remove whitespace and brackets
        cleaned = existing.strip()
        if cleaned.startswith("["):
            cleaned = cleaned[1:]
        if cleaned.endswith("]"):
            cleaned = cleaned[:-1]
        # Split by },{ 
        flows = cleaned.split("},{")
        for flow in flows:
            # Ensure braces
            if not flow.startswith("{"):
                flow = "{" + flow
            if not flow.endswith("}"):
                flow = flow + "}"
            # Check alias
            if '"alias"' in flow:
                # Find alias value
                idx = flow.find('"alias"')
                if idx >= 0:
                    after = flow[idx + len('"alias"'):].strip()
                    if after.startswith(":"):
                        after = after[1:].strip()
                    if after.startswith('"'):
                        after = after[1:]
                    if '"' in after:
                        alias_val = after[:after.find('"')]
                        if alias_val == alias:
                            auth_repr = flow
                            break

    # In check mode, determine if changes needed
    if ctx.check_mode:
        if state == "absent":
            if auth_repr:
                return {"changed": True, "msg": "would delete authentication flow"}
            else:
                return {"changed": False, "msg": "authentication flow absent"}
        else:  # present
            if not auth_repr:
                return {"changed": True, "msg": "would create authentication flow"}
            if force:
                return {"changed": True, "msg": "would recreate authentication flow"}
            # If executions provided, assume changes may be needed
            if auth_execs:
                return {"changed": True, "msg": "would update executions"}
            return {"changed": False, "msg": "authentication flow present"}

    # Main logic
    if state == "absent":
        if auth_repr:
            # Extract ID
            id_val = ""
            if '"id"' in auth_repr:
                idx = auth_repr.find('"id"')
                if idx >= 0:
                    after = auth_repr[idx + len('"id"'):].strip()
                    if after.startswith(":"):
                        after = after[1:].strip()
                    if after.startswith('"'):
                        after = after[1:]
                    if '"' in after:
                        id_val = after[:after.find('"')]
            if id_val:
                kc_delete("/authentication/flows/" + id_val)
                return {"changed": True, "msg": "authentication flow deleted"}
            else:
                fail("Could not determine flow ID for deletion")
        else:
            return {"changed": False, "msg": "authentication flow absent"}

    else:  # present
        # Check if flow exists
        if not auth_repr or force:
            # Delete if exists and force
            if auth_repr:
                id_val = ""
                if '"id"' in auth_repr:
                    idx = auth_repr.find('"id"')
                    if idx >= 0:
                        after = auth_repr[idx + len('"id"'):].strip()
                        if after.startswith(":"):
                            after = after[1:].strip()
                        if after.startswith('"'):
                            after = after[1:]
                        if '"' in after:
                            id_val = after[:after.find('"')]
                if id_val:
                    kc_delete("/authentication/flows/" + id_val)

            # Create new flow
            body = {"alias": alias}
            if description:
                body["description"] = description
            if provider_id:
                body["providerId"] = provider_id
            else:
                body["providerId"] = "basic-flow"

            # Convert body to JSON string manually (very basic)
            def to_json(obj):
                items = []
                for k, v in obj.items():
                    if isinstance(v, str):
                        items.append('"' + k + '":"' + v + '"')
                    elif isinstance(v, int):
                        items.append('"' + k + '":' + str(v))
                return "{" + ",".join(items) + "}"

            # Create the flow
            if copy_from:
                # Use copy endpoint
                res = ctx.run([
                    "curl", "-s", "-X", "POST",
                ] + headers + [
                    "-d", '{"copyFrom":"' + copy_from + '"}', auth_url + "/admin/realms/" + realm + "/authentication/flows",
                    "--connect-timeout", str(timeout), "--max-time", str(timeout)
                ])
                if res.rc != 201:
                    fail("Failed to copy authentication flow: " + res.stderr)
            else:
                res = ctx.run([
                    "curl", "-s", "-X", "POST",
                ] + headers + [
                    "-d", to_json(body), auth_url + "/admin/realms/" + realm + "/authentication/flows",
                    "--connect-timeout", str(timeout), "--max-time", str(timeout)
                ])
                if res.rc != 201:
                    fail("Failed to create authentication flow: " + res.stderr)

            # If no executions, return
            if not auth_execs:
                # Fetch created flow
                created = kc_get("/authentication/flows?alias=" + alias)
                return {"changed": True, "msg": "authentication flow created", "data": {"end_state": created}}

        # Now handle executions
        if auth_execs:
            # Get current executions
            current_execs_str = kc_get("/authentication/flows/" + alias + "/executions")
            current_execs = []
            if current_execs_str:
                # Very basic parse for JSON array
                cleaned = current_execs_str.strip()
                if cleaned.startswith("["):
                    cleaned = cleaned[1:]
                if cleaned.endswith("]"):
                    cleaned = cleaned[:-1]
                # Split by },{ 
                execs = cleaned.split("},{")
                for exec_str in execs:
                    # Ensure braces
                    if not exec_str.startswith("{"):
                        exec_str = "{" + exec_str
                    if not exec_str.endswith("}"):
                        exec_str = exec_str + "}"
                    current_execs.append(exec_str)

            for idx, new_exec in enumerate(auth_execs):
                provider_id_exec = new_exec.get("providerId")
                display_name = new_exec.get("displayName")

                # Find matching execution
                found_idx = -1
                for i, exec_str in enumerate(current_execs):
                    if provider_id_exec and '"providerId":"'+provider_id_exec+'"' in exec_str:
                        found_idx = i
                        break
                    if display_name and '"displayName":"'+display_name+'"' in exec_str:
                        found_idx = i
                        break

                if found_idx == -1:
                    # Create new execution or subflow
                    if provider_id_exec:
                        # Build execution body
                        exec_body = {"provider": provider_id_exec}
                        req = new_exec.get("requirement")
                        if req:
                            exec_body["requirement"] = req
                        index = new_exec.get("index")
                        if index != None:
                            exec_body["index"] = index
                        flow_alias = new_exec.get("flowAlias") or alias
                        exec_body["flowAlias"] = flow_alias

                        # Convert to JSON
                        body_json = "{"
                        for k, v in exec_body.items():
                            if isinstance(v, str):
                                body_json += '"' + k + '":"' + v + '",'
                            elif isinstance(v, int):
                                body_json += '"' + k + '":' + str(v) + ","
                        if body_json.endswith(","):
                            body_json = body_json[:-1]
                        body_json += "}"

                        # POST to executions
                        res = ctx.run([
                            "curl", "-s", "-X", "POST",
                        ] + headers + [
                            "-d", body_json, auth_url + "/admin/realms/" + realm + "/authentication/flows/" + alias + "/executions",
                            "--connect-timeout", str(timeout), "--max-time", str(timeout)
                        ])
                        if res.rc != 201:
                            fail("Failed to create execution: " + res.stderr)

                        # Add config if needed
                        auth_config = new_exec.get("authenticationConfig")
                        if auth_config:
                            # Get execution ID (naive: parse last response)
                            new_execs = kc_get("/authentication/flows/" + alias + "/executions")
                            exec_id = ""
                            if new_execs:
                                # Get the last created (assume it's the new one)
                                last_exec = ""
                                if new_execs.strip().endswith("]"):
                                    tmp = new_execs.strip()[:-1]
                                    if tmp.endswith("}"):
                                        last_exec = tmp.split("},{")[-1]
                                if last_exec.startswith("{") and not last_exec.endswith("}"):
                                    last_exec += "}"
                                if '"id"' in last_exec:
                                    id_start = last_exec.find('"id"')
                                    if id_start >= 0:
                                        after = last_exec[id_start + len('"id"'):].strip()
                                        if after.startswith(":"):
                                            after = after[1:].strip()
                                        if after.startswith('"'):
                                            after = after[1:]
                                        if '"' in after:
                                            exec_id = after[:after.find('"')]
                            if exec_id:
                                # Create config
                                cfg_body = {"alias": auth_config.get("alias", "config"), "config": auth_config.get("config", {})}
                                cfg_json = "{"
                                for k, v in cfg_body.items():
                                    if isinstance(v, str):
                                        cfg_json += '"' + k + '":"' + v + '",'
                                    elif isinstance(v, dict):
                                        cfg_json += '"' + k + '":{'
                                        for ck, cv in v.items():
                                            if isinstance(cv, str):
                                                cfg_json += '"' + ck + '":"' + cv + '",'
                                            else:
                                                cfg_json += '"' + ck + '":' + str(cv) + ","
                                        if cfg_json.endswith(","):
                                            cfg_json = cfg_json[:-1]
                                        cfg_json += "},"
                                if cfg_json.endswith(","):
                                    cfg_json = cfg_json[:-1]
                                cfg_json += "}"
                                cfg_res = ctx.run([
                                    "curl", "-s", "-X", "POST",
                                ] + headers + [
                                    "-d", cfg_json, auth_url + "/admin/realms/" + realm + "/authentication/config/" + exec_id,
                                    "--connect-timeout", str(timeout), "--max-time", str(timeout)
                                ])
                                if cfg_res.rc != 201:
                                    fail("Failed to create auth config: " + cfg_res.stderr)

                    elif display_name:
                        # Create subflow
                        flow_type = new_exec.get("subFlowType", "basic-flow")
                        subflow_body = {"alias": display_name, "providerId": "basic-flow", "type": flow_type}
                        sf_json = "{"
                        for k, v in subflow_body.items():
                            if isinstance(v, str):
                                sf_json += '"' + k + '":"' + v + '",'
                            else:
                                sf_json += '"' + k + '":' + str(v) + ","
                        if sf_json.endswith(","):
                            sf_json = sf_json[:-1]
                        sf_json += "}"
                        res = ctx.run([
                            "curl", "-s", "-X", "POST",
                        ] + headers + [
                            "-d", sf_json, auth_url + "/admin/realms/" + realm + "/authentication/flows/" + alias + "/subflows",
                            "--connect-timeout", str(timeout), "--max-time", str(timeout)
                        ])
                        if res.rc != 201:
                            fail("Failed to create subflow: " + res.stderr)

            # Update existing executions
            for idx, new_exec in enumerate(auth_execs):
                if not new_exec.get("providerId") and not new_exec.get("displayName"):
                    continue
                # Find in current_execs
                found = -1
                for i, exec_str in enumerate(current_execs):
                    if new_exec.get("providerId") and '"providerId":"'+new_exec["providerId"]+'"' in exec_str:
                        found = i
                        break
                    if new_exec.get("displayName") and '"displayName":"'+new_exec["displayName"]+'"' in exec_str:
                        found = i
                        break
                if found >= 0 and found != idx:
                    # Need to update index
                    exec_id = ""
                    if '"id"' in current_execs[found]:
                        id_line = current_execs[found]
                        idx_start = id_line.find('"id"')
                        if idx_start >= 0:
                            after = id_line[idx_start + len('"id"'):].strip()
                            if after.startswith(":"):
                                after = after[1:].strip()
                            if after.startswith('"'):
                                after = after[1:]
                            if '"' in after:
                                exec_id = after[:after.find('"')]
                    if exec_id:
                        # PUT update with new index
                        update_body = {"id": exec_id, "index": idx}
                        update_json = "{"
                        for k, v in update_body.items():
                            if isinstance(v, str):
                                update_json += '"' + k + '":"' + v + '",'
                            elif isinstance(v, int):
                                update_json += '"' + k + '":' + str(v) + ","
                        if update_json.endswith(","):
                            update_json = update_json[:-1]
                        update_json += "}"
                        res = ctx.run([
                            "curl", "-s", "-X", "PUT",
                        ] + headers + [
                            "-d", update_json, auth_url + "/admin/realms/" + realm + "/authentication/executions/" + exec_id,
                            "--connect-timeout", str(timeout), "--max-time", str(timeout)
                        ])
                        if res.rc != 204:
                            fail("Failed to update execution index: " + res.stderr)

                # Update requirement and config if changed
                if found >= 0:
                    exec_id = ""
                    if '"id"' in current_execs[found]:
                        id_line = current_execs[found]
                        idx_start = id_line.find('"id"')
                        if idx_start >= 0:
                            after = id_line[idx_start + len('"id"'):].strip()
                            if after.startswith(":"):
                                after = after[1:].strip()
                            if after.startswith('"'):
                                after = after[1:]
                            if '"' in after:
                                exec_id = after[:after.find('"')]
                    if exec_id:
                        req = new_exec.get("requirement")
                        if req:
                            update_body = {"id": exec_id, "requirement": req}
                            update_json = "{"
                            for k, v in update_body.items():
                                if isinstance(v, str):
                                    update_json += '"' + k + '":"' + v + '",'
                                elif isinstance(v, int):
                                    update_json += '"' + k + '":' + str(v) + ","
                                else:
                                    update_json += '"' + k + '":' + str(v) + ","
                            if update_json.endswith(","):
                                update_json = update_json[:-1]
                            update_json += "}"
                            res = ctx.run([
                                "curl", "-s", "-X", "PUT",
                            ] + headers + [
                                "-d", update_json, auth_url + "/admin/realms/" + realm + "/authentication/executions/" + exec_id,
                                "--connect-timeout", str(timeout), "--max-time", str(timeout)
                            ])
                            if res.rc != 204:
                                fail("Failed to update execution requirement: " + res.stderr)

                        # Update config
                        auth_config = new_exec.get("authenticationConfig")
                        if auth_config:
                            # Find existing config ID
                            config_id = ""
                            cfg_str = kc_get("/authentication/executions/" + exec_id + "/config")
                            if cfg_str:
                                # Parse config
                                cfg_lines = cfg_str.strip()
                                if cfg_lines.startswith("["):
                                    cfg_lines = cfg_lines[1:]
                                if cfg_lines.endswith("]"):
                                    cfg_lines = cfg_lines[:-1]
                                cfg_items = cfg_lines.split("},{")
                                for cfg in cfg_items:
                                    if not cfg.startswith("{"):
                                        cfg = "{" + cfg
                                    if not cfg.endswith("}"):
                                        cfg = cfg + "}"
                                    if '"alias"'+':'+'"'+auth_config.get("alias", "config")+'"' in cfg:
                                        if '"id"' in cfg:
                                            id_start = cfg.find('"id"')
                                            if id_start >= 0:
                                                after = cfg[id_start + len('"id"'):].strip()
                                                if after.startswith(":"):
                                                    after = after[1:].strip()
                                                if after.startswith('"'):
                                                    after = after[1:]
                                                if '"' in after:
                                                    config_id = after[:after.find('"')]
                                                    break
                            if config_id:
                                # PUT update config
                                cfg_body = {"id": config_id, "alias": auth_config.get("alias", "config"), "config": auth_config.get("config", {})}
                                cfg_json = "{"
                                for k, v in cfg_body.items():
                                    if isinstance(v, str):
                                        cfg_json += '"' + k + '":"' + v + '",'
                                    elif isinstance(v, dict):
                                        cfg_json += '"' + k + '":{'
                                        for ck, cv in v.items():
                                            if isinstance(cv, str):
                                                cfg_json += '"' + ck + '":"' + cv + '",'
                                            else:
                                                cfg_json += '"' + ck + '":' + str(cv) + ","
                                        if cfg_json.endswith(","):
                                            cfg_json = cfg_json[:-1]
                                        cfg_json += "},"
                                    else:
                                        cfg_json += '"' + k + '":' + str(v) + ","
                                if cfg_json.endswith(","):
                                    cfg_json = cfg_json[:-1]
                                cfg_json += "}"
                                res = ctx.run([
                                    "curl", "-s", "-X", "PUT",
                                ] + headers + [
                                    "-d", cfg_json, auth_url + "/admin/realms/" + realm + "/authentication/config/" + config_id,
                                    "--connect-timeout", str(timeout), "--max-time", str(timeout)
                                ])
                                if res.rc != 204:
                                    fail("Failed to update config: " + res.stderr)
                            else:
                                # POST new config
                                cfg_body = {"alias": auth_config.get("alias", "config"), "config": auth_config.get("config", {})}
                                cfg_json = "{"
                                for k, v in cfg_body.items():
                                    if isinstance(v, str):
                                        cfg_json += '"' + k + '":"' + v + '",'
                                    elif isinstance(v, dict):
                                        cfg_json += '"' + k + '":{'
                                        for ck, cv in v.items():
                                            if isinstance(cv, str):
                                                cfg_json += '"' + ck + '":"' + cv + '",'
                                            else:
                                                cfg_json += '"' + ck + '":' + str(cv) + ","
                                        if cfg_json.endswith(","):
                                            cfg_json = cfg_json[:-1]
                                        cfg_json += "},"
                                    else:
                                        cfg_json += '"' + k + '":' + str(v) + ","
                                if cfg_json.endswith(","):
                                    cfg_json = cfg_json[:-1]
                                cfg_json += "}"
                                res = ctx.run([
                                    "curl", "-s", "-X", "POST",
                                ] + headers + [
                                    "-d", cfg_json, auth_url + "/admin/realms/" + realm + "/authentication/executions/" + exec_id + "/config",
                                    "--connect-timeout", str(timeout), "--max-time", str(timeout)
                                ])
                                if res.rc != 201:
                                    fail("Failed to create config: " + res.stderr)

        return {"changed": True, "msg": "authentication flow created or updated"}
