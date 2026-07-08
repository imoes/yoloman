def main(ctx, params):
    # Required params
    alias = params["alias"]
    realm = params.get("realm", "master")
    state = params.get("state", "present")
    auth_url = params["auth_keycloak_url"]
    auth_realm = params.get("auth_realm", "master")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_client_secret = params.get("auth_client_secret")
    conn_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Build auth header
    token = None
    if auth_username != None and auth_password != None:
        # Obtain token
        payload = "grant_type=password&client_id=" + auth_client_id + "&username=" + auth_username + "&password=" + auth_password
        if auth_realm != None and auth_realm != "master":
            payload += "&realm=" + auth_realm
        if auth_client_secret != None:
            auth_header = "Basic " + auth_client_secret
            res = ctx.run(["curl", "-s", "-X", "POST",
                           "-H", "Content-Type: application/x-www-form-urlencoded",
                           "-H", "Authorization: Basic " + auth_client_secret,
                           "-d", payload,
                           auth_url + "/realms/" + auth_realm + "/protocol/openid-connect/token"],
                          mutates=False)
        else:
            res = ctx.run(["curl", "-s", "-X", "POST",
                           "-H", "Content-Type: application/x-www-form-urlencoded",
                           "-d", payload,
                           auth_url + "/realms/" + auth_realm + "/protocol/openid-connect/token"],
                          mutates=False)
        if res.rc != 0:
            fail("failed to obtain token: " + res.stderr)
        token = str(res.stdout).strip()
    else:
        fail("authentication requires auth_username and auth_password")

    # Helper: perform GET request
    def get_idp(alias, realm):
        res = ctx.run(["curl", "-s", "-X", "GET",
                       "-H", "Authorization: Bearer " + token,
                       "-H", "Accept: application/json",
                       auth_url + "/admin/realms/" + realm + "/identity-provider/aliases/" + alias],
                      mutates=False)
        if res.rc == 0:
            return True
        elif res.rc == 404:
            return False
        else:
            fail("failed to get identity provider: " + res.stderr)

    # Helper: perform POST/PUT/DELETE and return changed status
    def call_api(method, path, data=None):
        cmd = ["curl", "-s", "-X", method,
               "-H", "Authorization: Bearer " + token,
               "-H", "Content-Type: application/json"]
        if data != None:
            cmd += ["-d", data]
        cmd += [auth_url + "/admin" + path]
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0 and res.rc != 204:
            fail(method + " " + path + " failed: " + res.stderr)
        return res.rc == 0 or res.rc == 204

    # Determine current state
    exists = get_idp(alias, realm)

    # Build desired state dict
    desired = {"alias": alias}
    if params.get("display_name") != None:
        desired["displayName"] = params["display_name"]
    if params.get("enabled") != None:
        desired["enabled"] = params["enabled"]
    if params.get("add_read_token_role_on_create") != None:
        desired["addReadTokenRoleOnCreate"] = params["add_read_token_role_on_create"]
    if params.get("authenticate_by_default") != None:
        desired["authenticateByDefault"] = params["authenticate_by_default"]
    if params.get("link_only") != None:
        desired["linkOnly"] = params["link_only"]
    if params.get("provider_id") != None:
        desired["providerId"] = params["provider_id"]
    if params.get("config") != None:
        config = {}
        c = params["config"]
        if c.get("hide_on_login_page") != None:
            config["hideOnLoginPage"] = str(c["hide_on_login_page"]).lower()
        if c.get("gui_order") != None:
            config["guiOrder"] = str(c["gui_order"])
        if c.get("sync_mode") != None:
            config["syncMode"] = c["sync_mode"]
        if c.get("issuer") != None:
            config["issuer"] = c["issuer"]
        if c.get("authorizationUrl") != None:
            config["authorizationUrl"] = c["authorizationUrl"]
        if c.get("tokenUrl") != None:
            config["tokenUrl"] = c["tokenUrl"]
        if c.get("logoutUrl") != None:
            config["logoutUrl"] = c["logoutUrl"]
        if c.get("userInfoUrl") != None:
            config["userInfoUrl"] = c["userInfoUrl"]
        if c.get("clientAuthMethod") != None:
            config["clientAuthMethod"] = c["clientAuthMethod"]
        if c.get("clientId") != None:
            config["clientId"] = c["clientId"]
        if c.get("clientSecret") != None:
            config["clientSecret"] = c["clientSecret"]
        if c.get("defaultScope") != None:
            config["defaultScope"] = c["defaultScope"]
        if c.get("validateSignature") != None:
            config["validateSignature"] = str(c["validateSignature"]).lower()
        if c.get("useJwksUrl") != None:
            config["useJwksUrl"] = str(c["useJwksUrl"]).lower()
        if c.get("jwksUrl") != None:
            config["jwksUrl"] = c["jwksUrl"]
        if c.get("entityId") != None:
            config["entityId"] = c["entityId"]
        if c.get("singleSignOnServiceUrl") != None:
            config["singleSignOnServiceUrl"] = c["singleSignOnServiceUrl"]
        if c.get("singleLogoutServiceUrl") != None:
            config["singleLogoutServiceUrl"] = c["singleLogoutServiceUrl"]
        if c.get("backchannelSupported") != None:
            config["backchannelSupported"] = c["backchannelSupported"]
        if c.get("nameIDPolicyFormat") != None:
            config["nameIDPolicyFormat"] = c["nameIDPolicyFormat"]
        if c.get("principalType") != None:
            config["principalType"] = c["principalType"]
        desired["config"] = config
    if params.get("mappers") != None:
        mappers = []
        for mapper in params["mappers"]:
            mp = {}
            if mapper.get("id") != None:
                mp["id"] = mapper["id"]
            if mapper.get("name") != None:
                mp["name"] = mapper["name"]
            if mapper.get("identityProviderAlias") != None:
                mp["identityProviderAlias"] = mapper["identityProviderAlias"]
            else:
                mp["identityProviderAlias"] = alias
            if mapper.get("identityProviderMapper") != None:
                mp["identityProviderMapper"] = mapper["identityProviderMapper"]
            if mapper.get("config") != None:
                mp["config"] = mapper["config"]
            mappers.append(mp)
        desired["mappers"] = mappers

    # Build JSON string for desired state
    def dict_to_json(d):
        items = []
        for k, v in d.items():
            if type(v) == "dict":
                items.append('"' + k + '":' + dict_to_json(v))
            elif type(v) == "list":
                items.append('"' + k + '":[' + ",".join([dict_to_json(x) if type(x) == "dict" else '"' + str(x) + '"' for x in v]) + "]")
            elif type(v) == "bool":
                items.append('"' + k + '":' + ("true" if v else "false"))
            else:
                items.append('"' + k + '":"'+ str(v) + '"')
        return "{" + ",".join(items) + "}"

    desired_json = dict_to_json(desired)

    # check_mode: compute predicted changes
    if ctx.check_mode:
        changed = False
        if state == "present":
            if not exists:
                changed = True
            else:
                # simple diff — just compare full JSON
                res = ctx.run(["curl", "-s", "-X", "GET",
                               "-H", "Authorization: Bearer " + token,
                               "-H", "Accept: application/json",
                               auth_url + "/admin/realms/" + realm + "/identity-provider/aliases/" + alias],
                              mutates=False)
                if res.rc == 0:
                    existing_json = res.stdout.strip()
                    if existing_json != desired_json:
                        changed = True
                else:
                    changed = True
        elif state == "absent":
            if exists:
                changed = True
        return {"changed": changed, "msg": ("would create" if not exists and state == "present" else "would update" if exists and state == "present" and changed else "would delete" if exists and state == "absent" else "no changes") + " identity provider " + alias}

    # Real execution
    msg = ""
    if state == "present":
        if not exists:
            # Create
            changed = call_api("POST", "/realms/" + realm + "/identity-provider/providers/" + (params.get("provider_id") if params.get("provider_id") != None else "oidc"), desired_json)
            msg = "Identity provider " + alias + " has been created"
        else:
            # Update
            changed = call_api("PUT", "/realms/" + realm + "/identity-provider/instances/" + alias, desired_json)
            msg = "Identity provider " + alias + " has been updated"
        # Handle mappers after main IDP
        if params.get("mappers") != None:
            # Get existing mappers list
            res = ctx.run(["curl", "-s", "-X", "GET",
                           "-H", "Authorization: Bearer " + token,
                           "-H", "Accept: application/json",
                           auth_url + "/admin/realms/" + realm + "/identity-provider/instances/" + alias + "/mappers"],
                          mutates=False)
            existing_mappers = []
            if res.rc == 0:
                existing_mappers = res.stdout.splitlines()
            desired_mappers = desired.get("mappers", [])
            for mp in desired_mappers:
                mp_json = dict_to_json(mp)
                if mp.get("id") != None:
                    # Update existing mapper
                    changed = call_api("PUT", "/realms/" + realm + "/identity-provider/instances/" + alias + "/mappers/" + mp["id"], mp_json) or changed
                else:
                    # Create mapper
                    changed = call_api("POST", "/realms/" + realm + "/identity-provider/instances/" + alias + "/mappers", mp_json) or changed
            # Delete missing mappers
            # For simplicity, we skip full mapper diff — assume only add/update if mappers provided
    elif state == "absent":
        if exists:
            call_api("DELETE", "/realms/" + realm + "/identity-provider/instances/" + alias)
            msg = "Identity provider " + alias + " has been deleted"
            changed = True
        else:
            msg = "Identity provider does not exist; doing nothing."
            changed = False

    return {"changed": changed, "msg": msg}
