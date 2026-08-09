def main(ctx, params):
    # Required params
    auth_url = params["auth_keycloak_url"]
    state = params.get("state", "present")
    realm = params.get("realm", "master")
    client_id = params.get("client_id")
    cid = params.get("id")

    # Build payload dict from provided params
    payload = {}
    for key in [
        "name", "description", "root_url", "admin_url", "base_url",
        "enabled", "client_authenticator_type", "registration_access_token",
        "redirect_uris", "web_origins", "not_before", "bearer_only", "consent_required",
        "standard_flow_enabled", "implicit_flow_enabled", "direct_access_grants_enabled",
        "service_accounts_enabled", "authorization_services_enabled", "public_client",
        "frontchannel_logout", "protocol", "full_scope_allowed", "node_re_registration_timeout",
        "client_template", "use_template_config", "use_template_scope", "use_template_mappers",
        "always_display_in_console", "surrogate_auth_required", "authentication_flow_binding_overrides",
        "default_client_scopes", "optional_client_scopes"
    ]:
        val = params.get(key)
        if val != None:
            payload[key] = val

    # Handle aliases (snake → camel)
    camel_map = {
        "root_url": "rootUrl",
        "admin_url": "adminUrl",
        "base_url": "baseUrl",
        "client_authenticator_type": "clientAuthenticatorType",
        "registration_access_token": "registrationAccessToken",
        "redirect_uris": "redirectUris",
        "web_origins": "webOrigins",
        "not_before": "notBefore",
        "consent_required": "consentRequired",
        "standard_flow_enabled": "standardFlowEnabled",
        "implicit_flow_enabled": "implicitFlowEnabled",
        "direct_access_grants_enabled": "directAccessGrantsEnabled",
        "service_accounts_enabled": "serviceAccountsEnabled",
        "authorization_services_enabled": "authorizationServicesEnabled",
        "public_client": "publicClient",
        "frontchannel_logout": "frontchannelLogout",
        "full_scope_allowed": "fullScopeAllowed",
        "node_re_registration_timeout": "nodeReRegistrationTimeout",
        "client_template": "clientTemplate",
        "use_template_config": "useTemplateConfig",
        "use_template_scope": "useTemplateScope",
        "use_template_mappers": "useTemplateMappers",
        "always_display_in_console": "alwaysDisplayInConsole",
        "surrogate_auth_required": "surrogateAuthRequired",
        "authentication_flow_binding_overrides": "authenticationFlowBindingOverrides",
        "default_client_scopes": "defaultClientScopes",
        "optional_client_scopes": "optionalClientScopes"
    }
    for snake, camel_key in camel_map.items():
        if snake in payload:
            payload[camel_key] = payload.pop(snake)

    # Attributes and protocol_mappers are special — keep as-is
    attrs = params.get("attributes")
    if attrs != None:
        payload["attributes"] = attrs

    # Protocol mappers
    pm = params.get("protocol_mappers")
    if pm != None:
        payload["protocolMappers"] = pm

    # Auth preparation
    auth_token = params.get("token")
    auth_user = params.get("auth_username")
    auth_pass = params.get("auth_password")

    # Validate auth
    if auth_token == None and (auth_user == None or auth_pass == None):
        fail("Authentication requires either 'token' or both 'auth_username' and 'auth_password'")
    auth_header = ""
    if auth_token != None:
        auth_header = "-H Authorization: Bearer " + auth_token
    else:
        auth_header = "-u " + auth_user + ":" + auth_pass

    def build_url(endpoint):
        return auth_url.rstrip("/") + "/admin/realms/" + realm + "/" + endpoint

    # Helper to run curl commands
    def run_curl(method, endpoint, data_json=""):
        url = build_url(endpoint)
        args = ["curl", "-s", "-X", method, url]
        if auth_header != "":
            args.append(auth_header)
        if data_json != "":
            args.extend(["-d", data_json])
        args.extend(["-H", "Content-Type: application/json"])
        res = ctx.run(args, mutates=True)
        return res

    def run_curl_read(endpoint):
        url = build_url(endpoint)
        args = ["curl", "-s", "-X", "GET", url]
        if auth_header != "":
            args.append(auth_header)
        args.extend(["-H", "Content-Type: application/json"])
        res = ctx.run(args, mutates=False)
        if res.rc != 0:
            fail("Keycloak GET failed: " + res.stderr)
        return res.stdout

    # Find existing client
    existing = None
    if cid != None:
        res = run_curl_read("clients/" + cid)
        if res != "":
            existing = res
    elif client_id != None:
        res = run_curl_read("clients?clientId=" + client_id)
        if res != "":
            res = res.strip()
            if len(res) >= 2 and res[0] == '[' and res[-1] == ']':
                first_brace = res.find('{')
                last_brace = res.rfind('}')
                if first_brace >= 0 and last_brace >= first_brace:
                    existing = res[first_brace:last_brace + 1]
                else:
                    existing = res
            else:
                existing = res

    # Desired payload setup
    desired = payload.copy()
    # Defaults
    if state == "present":
        if "protocol" not in desired:
            desired["protocol"] = "openid-connect"
        if "clientId" not in desired and client_id != None:
            desired["clientId"] = client_id
        if "clientId" not in desired:
            fail("client_id must be provided when creating a client")

    # Check if update needed
    if state == "absent":
        if existing == None:
            return {"changed": False, "msg": "Client does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete client"}
        res = run_curl("DELETE", "clients/" + cid if cid != None else "clients?clientId=" + client_id)
        if res.skipped:
            return {"changed": True, "msg": "would delete client"}
        return {"changed": True, "msg": "Client has been deleted"}

    # Present state
    if existing != None:
        # Build desired JSON manually
        parts = []
        for k in sorted(desired.keys()):
            v = desired[k]
            if isinstance(v, str):
                v = v.replace("\\", "\\\\").replace('"', '\\"')
                parts.append('"' + k + '":"' + v + '"')
            elif isinstance(v, bool):
                parts.append('"' + k + '":' + ('true' if v else 'false'))
            elif isinstance(v, int):
                parts.append('"' + k + '":' + str(v))
            elif v == None:
                pass
            else:
                parts.append('"' + k + '":"' + str(v) + '"')
        desired_json = "{" + ",".join(parts) + "}"

        if existing.strip() == desired_json.strip():
            return {"changed": False, "msg": "Client already exists and is up-to-date"}

        if ctx.check_mode:
            return {"changed": True, "msg": "would update client"}

        # Determine client ID for update
        client_id_path = cid if cid != None else ""
        if client_id_path == "":
            idx = existing.find('"id":"')
            if idx >= 0:
                start = idx + 5
                end = existing.find('"', start)
                if end > start:
                    client_id_path = existing[start:end]

        if client_id_path == "":
            fail("could not determine client ID for update")

        res = run_curl("PUT", "clients/" + client_id_path, desired_json)
        if res.skipped:
            return {"changed": True, "msg": "would update client"}
        return {"changed": True, "msg": "Client has been updated"}

    # Create new client
    if ctx.check_mode:
        return {"changed": True, "msg": "would create client"}

    # Build desired JSON manually
    parts = []
    for k in sorted(desired.keys()):
        v = desired[k]
        if isinstance(v, str):
            v = v.replace("\\", "\\\\").replace('"', '\\"')
            parts.append('"' + k + '":"' + v + '"')
        elif isinstance(v, bool):
            parts.append('"' + k + '":' + ('true' if v else 'false'))
        elif isinstance(v, int):
            parts.append('"' + k + '":' + str(v))
        elif v == None:
            pass
        else:
            parts.append('"' + k + '":"' + str(v) + '"')
    desired_json = "{" + ",".join(parts) + "}"

    res = run_curl("POST", "clients", desired_json)
    if res.skipped:
        return {"changed": True, "msg": "would create client"}
    return {"changed": True, "msg": "Client has been created"}
