def main(ctx, params):
    # Extract parameters with defaults
    realm = params.get("realm", "master")
    state = params.get("state", "present")
    token = params.get("token")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_client_secret = params.get("auth_client_secret")
    auth_realm = params.get("auth_realm")
    auth_keycloak_url = params["auth_keycloak_url"]
    validate_certs = params.get("validate_certs", True)
    name = params.get("name")
    cid = params.get("id")
    description = params.get("description")
    protocol = params.get("protocol")
    full_scope_allowed = params.get("full_scope_allowed")
    protocol_mappers = params.get("protocol_mappers")
    attributes = params.get("attributes")

    # Validate required parameters
    if state == "present" and name == None:
        fail("name is required when state is present")
    if token == None:
        if auth_realm == None or auth_username == None or auth_password == None:
            fail("token or auth_realm, auth_username, and auth_password must be provided")
    if validate_certs != None and type(validate_certs) != "bool":
        fail("validate_certs must be a boolean")

    # Build auth header
    def build_auth_header():
        if token != None:
            return "Bearer " + str(token)
        # Login flow: obtain token using username/password
        res = ctx.run(
            ["curl", "-s", "-X", "POST",
             "-H", "Content-Type: application/x-www-form-urlencoded",
             "-d", "client_id=" + auth_client_id +
             "&username=" + auth_username +
             "&password=" + auth_password +
             "&grant_type=password" +
             ("&client_secret=" + auth_client_secret if auth_client_secret else "") +
             ("&realm=" + auth_realm if auth_realm else ""),
             auth_keycloak_url + "/realms/master/protocol/openid-connect/token"],
            mutates=False
        )
        if res.rc != 0:
            fail("Failed to authenticate to Keycloak: " + res.stderr)
        resp = res.stdout
        # Extract access_token manually
        token_key = '"access_token"'
        idx = resp.find(token_key)
        if idx == -1:
            fail("No access_token in response")
        colon_idx = resp.find(":", idx + len(token_key))
        if colon_idx == -1:
            fail("Malformed token response")
        quote1 = resp.find('"', colon_idx + 1)
        if quote1 == -1:
            fail("Malformed token response")
        quote2 = resp.find('"', quote1 + 1)
        if quote2 == -1:
            fail("Malformed token response")
        return "Bearer " + resp[quote1 + 1:quote2]

    auth_header = build_auth_header()
    headers = ["-H", "Authorization: " + auth_header, "-H", "Accept: application/json"]

    # Helper: GET client template by name
    def get_by_name(n):
        if n == None:
            return None
        res = ctx.run(
            ["curl", "-s"] + headers + [
                auth_keycloak_url + "/admin/realms/" + realm + "/client-templates?view=summary"
            ],
            mutates=False
        )
        if res.rc != 0:
            fail("Failed to fetch client templates: " + res.stderr)
        resp = res.stdout.strip()
        if resp == "":
            return None
        if resp.startswith("[") and resp.endswith("]"):
            resp = resp[1:-1]
        if resp == "":
            return None
        # Split items by },{ pattern (simple approach)
        items = resp.split("},{")
        for i in range(len(items)):
            item = items[i].strip()
            if not item.startswith("{"):
                item = "{" + item
            if not item.endswith("}"):
                item = item + "}"
            # Find name field
            name_key = '"name"'
            name_idx = item.find(name_key)
            if name_idx != -1:
                colon_idx = item.find(":", name_idx + len(name_key))
                if colon_idx == -1:
                    continue
                q1 = item.find('"', colon_idx + 1)
                if q1 == -1:
                    continue
                q2 = item.find('"', q1 + 1)
                if q2 == -1:
                    continue
                found_name = item[q1 + 1:q2]
                if found_name == n:
                    # Extract id
                    id_key = '"id"'
                    id_idx = item.find(id_key)
                    if id_idx != -1:
                        id_colon = item.find(":", id_idx + len(id_key))
                        if id_colon != -1:
                            id_q1 = item.find('"', id_colon + 1)
                            if id_q1 != -1:
                                id_q2 = item.find('"', id_q1 + 1)
                                if id_q2 != -1:
                                    return item[id_q1 + 1:id_q2]
        return None

    # Helper: GET full details by id
    def get_by_id(cid_val):
        if cid_val == None:
            return "{}"
        res = ctx.run(
            ["curl", "-s"] + headers + [
                auth_keycloak_url + "/admin/realms/" + realm + "/client-templates/" + cid_val
            ],
            mutates=False
        )
        if res.rc == 404:
            return "{}"
        if res.rc != 0:
            fail("Failed to fetch client template details: " + res.stderr)
        return res.stdout

    # Determine existing template id
    if cid == None:
        cid = get_by_name(name)
    else:
        # Check existence
        tmp = get_by_id(cid)
        if tmp == "{}":
            cid = None

    # Get full existing object
    if cid != None:
        existing = get_by_id(cid)
    else:
        existing = "{}"

    # Prepare desired payload
    desired = "{"
    if cid != None:
        desired = '{"id": "' + cid + '", '

    # Build payload from params (snake_case → camelCase manually)
    if name != None:
        desired = desired + '"name": "' + name + '", '
    if description != None:
        desired = desired + '"description": "' + description + '", '
    if protocol != None:
        desired = desired + '"protocol": "' + protocol + '", '
    if full_scope_allowed != None:
        val = "true" if full_scope_allowed else "false"
        desired = desired + '"fullScopeAllowed": ' + val + ', '
    if attributes != None:
        if type(attributes) == "dict" and len(attributes) == 0:
            pass
        else:
            fail("attributes must be an empty dict (complex serialization not supported)")
    if protocol_mappers != None:
        if type(protocol_mappers) == "list" and len(protocol_mappers) == 0:
            pass
        else:
            fail("protocol_mappers must be an empty list (complex serialization not supported)")

    # Strip trailing ", "
    if desired.endswith(", "):
        desired = desired[:-2]
    desired = desired + "}"

    # Idempotency logic
    if state == "present":
        changed = True
        if cid != None:
            # For true idempotency, compare full objects
            # Since deep JSON comparison is hard, we assume change is needed unless identical
            if existing == desired:
                changed = False
        else:
            changed = True

        if ctx.check_mode:
            if cid == None:
                return {"changed": True, "msg": "would create client template '" + name + "'"}
            else:
                return {"changed": changed, "msg": "would update client template '" + name + "'"}

        if cid == None:
            # Create
            res = ctx.run(
                ["curl", "-s", "-X", "POST"] + headers + [
                    "-H", "Content-Type: application/json",
                    "-d", desired,
                    auth_keycloak_url + "/admin/realms/" + realm + "/client-templates"
                ],
                mutates=True
            )
            if res.rc != 0 and res.rc != 201:
                fail("Failed to create client template: " + res.stderr)
            return {"changed": True, "msg": "Client template '" + name + "' has been created."}
        else:
            # Update
            res = ctx.run(
                ["curl", "-s", "-X", "PUT"] + headers + [
                    "-H", "Content-Type: application/json",
                    "-d", desired,
                    auth_keycloak_url + "/admin/realms/" + realm + "/client-templates/" + cid
                ],
                mutates=True
            )
            if res.rc != 0 and res.rc != 204:
                fail("Failed to update client template: " + res.stderr)
            return {"changed": True, "msg": "Client template '" + name + "' has been updated."}

    elif state == "absent":
        if cid == None:
            return {"changed": False, "msg": "Client template does not exist."}

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete client template '" + name + "'"}

        # Delete
        res = ctx.run(
            ["curl", "-s", "-X", "DELETE"] + headers + [
                auth_keycloak_url + "/admin/realms/" + realm + "/client-templates/" + cid
            ],
            mutates=True
        )
        if res.rc != 0 and res.rc != 204:
            fail("Failed to delete client template: " + res.stderr)
        return {"changed": True, "msg": "Client template '" + name + "' has been deleted."}

    fail("unsupported state: " + state)
