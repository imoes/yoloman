def main(ctx, params):
    # Extract required params
    name = params["name"]
    permission_type = params["permission_type"]
    client_id = params["client_id"]
    realm = params["realm"]
    state = params.get("state", "present")

    # Optional params with defaults
    description = params.get("description")
    decision_strategy = params.get("decision_strategy", "UNANIMOUS")
    resources = params.get("resources", [])
    scopes = params.get("scopes", [])
    policies = params.get("policies", [])
    auth_url = params["auth_keycloak_url"]
    auth_realm = params.get("auth_realm")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_client_secret = params.get("auth_client_secret")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)
    http_agent = params.get("http_agent", "Ansible")

    # Validate permission_type constraints for present state
    if state == "present":
        if permission_type == "scope":
            if len(scopes) == 0:
                fail("Scopes need to defined when permission type is set to scope!")
            if len(resources) > 1:
                fail("Only one resource can be defined for a scope permission!")
        elif permission_type == "resource":
            if len(resources) == 0:
                fail("A resource need to defined when permission type is set to resource!")
            if len(scopes) > 0:
                fail("Scopes cannot be defined when permission type is set to resource!")

    # Validate validate_certs
    if validate_certs == False:
        fail("validate_certs=false is not supported in Starlark")

    # Obtain access token (using token if provided, otherwise username/password)
    headers = {"User-Agent": http_agent}
    if token != None:
        auth_header = "Bearer " + token
    else:
        if auth_realm == None or auth_username == None or auth_password == None:
            fail("When token is not provided, auth_realm, auth_username, and auth_password must be provided")
        # Token endpoint
        token_path = "/realms/" + auth_realm + "/protocol/openid-connect/token"
        token_data = (
            "client_id=" + auth_client_id +
            "&grant_type=password" +
            "&username=" + auth_username +
            "&password=" + auth_password
        )
        if auth_client_secret != None:
            token_data += "&client_secret=" + auth_client_secret

        token_res = ctx.run(
            [
                "curl",
                "-s", "-S",
                "-X", "POST",
                "-H", "Content-Type: application/x-www-form-urlencoded",
                "-d", token_data,
                auth_url + token_path
            ],
            ok_codes=[0, 200]
        )
        if token_res.skipped:
            fail("Token retrieval skipped in check_mode")
        if token_res.rc != 0:
            fail("Failed to retrieve token: " + token_res.stderr)
        # Parse JSON manually (no json module) — simple extraction
        token_json = token_res.stdout.strip()
        if '"access_token"' not in token_json:
            fail("Token response missing access_token")
        # Extract token value between quotes after "access_token":
        start = token_json.find('"access_token":"') + len('"access_token":"')
        end = token_json.find('"', start)
        if end == -1:
            fail("Failed to parse access_token from response")
        auth_header = "Bearer " + token_json[start:end]

    headers["Authorization"] = auth_header
    headers["Content-Type"] = "application/json"

    # Get client ID from name
    client_search_url = auth_url + "/admin/realms/" + realm + "/clients?clientId=" + client_id
    client_res = ctx.run(
        [
            "curl",
            "-s", "-S",
            "-H", "Authorization: " + auth_header,
            "-H", "Content-Type: application/json",
            client_search_url
        ],
        ok_codes=[0]
    )
    if client_res.skipped:
        fail("Client lookup skipped in check_mode")
    if client_res.rc != 0:
        fail("Failed to lookup client: " + client_res.stderr)
    clients = client_res.stdout.strip()
    if clients == "[]" or len(clients) == 0:
        fail("Invalid client %s for realm %s" % (client_id, realm))
    # Assume first match (simple extraction)
    cid_start = clients.find('"id":"') + len('"id":"')
    if cid_start - len('"id":"') <= 0:
        fail("Failed to parse client id")
    cid_end = clients.find('"', cid_start)
    if cid_end == -1:
        fail("Failed to parse client id")
    cid = clients[cid_start:cid_end]

    # Get existing permission by name
    permission_url = auth_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/permission"
    perm_search_res = ctx.run(
        [
            "curl",
            "-s", "-S",
            "-H", "Authorization: " + auth_header,
            "-H", "Content-Type: application/json",
            permission_url + "?name=" + name
        ],
        ok_codes=[0]
    )
    if perm_search_res.skipped:
        fail("Permission lookup skipped in check_mode")
    if perm_search_res.rc != 0:
        fail("Failed to lookup permission: " + perm_search_res.stderr)
    permission_json = perm_search_res.stdout.strip()
    permission = None
    if permission_json != "[]" and len(permission_json) > 2:
        # Parse first permission object (simple extraction)
        if '"name":"' + name + '"' in permission_json:
            # Extract id and type from the first permission entry
            perm_start = permission_json.find("{")
            if perm_start == -1:
                fail("Failed to parse permission JSON")
            # Find end of the object (naive matching braces)
            brace_count = 0
            perm_end = -1
            for i in range(perm_start, len(permission_json)):
                if permission_json[i] == '{':
                    brace_count += 1
                elif permission_json[i] == '}':
                    brace_count -= 1
                    if brace_count == 0:
                        perm_end = i + 1
                        break
            if perm_end == -1:
                fail("Failed to parse permission JSON")
            perm_str = permission_json[perm_start:perm_end]
            # Extract id, type, decisionStrategy, description, etc.
            id_start = perm_str.find('"id":"') + len('"id":"')
            id_end = perm_str.find('"', id_start)
            if id_end != -1 and id_start > len('"id":"'):
                permission_id = perm_str[id_start:id_end]
            else:
                fail("Failed to extract permission id")
            type_start = perm_str.find('"type":"') + len('"type":"')
            type_end = perm_str.find('"', type_start)
            permission_type_current = perm_str[type_start:type_end] if type_end > type_start else None

            # Extract decision_strategy
            ds_start = perm_str.find('"decisionStrategy":"') + len('"decisionStrategy":"')
            ds_end = perm_str.find('"', ds_start)
            if ds_end != -1 and ds_start > len('"decisionStrategy":"'):
                permission_decision_strategy = perm_str[ds_start:ds_end]
            else:
                permission_decision_strategy = None

            # Extract description
            desc_start = perm_str.find('"description":"') + len('"description":"')
            desc_end = perm_str.find('"', desc_start)
            if desc_end != -1 and desc_start > len('"description":"'):
                permission_description = perm_str[desc_start:desc_end]
            else:
                permission_description = None

            permission = {
                "id": permission_id,
                "type": permission_type_current or "",
                "decisionStrategy": permission_decision_strategy,
                "description": permission_description
            }

    # Build payload
    payload = {
        "name": name,
        "type": permission_type,
        "decisionStrategy": decision_strategy,
        "logic": "POSITIVE",
        "resources": [],
        "scopes": [],
        "policies": []
    }
    if description != None:
        payload["description"] = description

    # Resolve resources and scopes
    if permission_type == "scope":
        if len(resources) > 0:
            # Get first resource id
            r_url = auth_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/resource?name=" + resources[0]
            r_res = ctx.run(
                [
                    "curl",
                    "-s", "-S",
                    "-H", "Authorization: " + auth_header,
                    r_url
                ],
                ok_codes=[0]
            )
            if r_res.skipped:
                fail("Resource lookup skipped in check_mode")
            if r_res.rc != 0:
                fail("Failed to lookup resource: " + r_res.stderr)
            r_json = r_res.stdout.strip()
            if r_json == "[]" or len(r_json) == 0:
                fail("Unable to find authorization resource with name %s for client %s in realm %s" % (resources[0], client_id, realm))
            # Extract _id (Keycloak uses _id for resources)
            rid_start = r_json.find('"_id":"') + len('"_id":"')
            rid_end = r_json.find('"', rid_start)
            if rid_end != -1 and rid_start > len('"_id":"'):
                rid = r_json[rid_start:rid_end]
            else:
                fail("Failed to extract resource id")
            payload["resources"].append(rid)

            # Also fetch scopes to validate against resource's scopes
            scope_url = auth_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/resource/" + rid + "/scopes"
            sc_res = ctx.run(
                [
                    "curl",
                    "-s", "-S",
                    "-H", "Authorization: " + auth_header,
                    scope_url
                ],
                ok_codes=[0]
            )
            if sc_res.skipped:
                fail("Scopes lookup skipped in check_mode")
            if sc_res.rc != 0:
                fail("Failed to lookup resource scopes: " + sc_res.stderr)
            sc_json = sc_res.stdout.strip()
            resource_scope_ids = []
            if sc_json != "[]" and len(sc_json) > 0:
                # Simple extraction of scope ids
                # Extract all "id" fields from scopes list
                while '"id":"' in sc_json:
                    sid_start = sc_json.find('"id":"') + len('"id":"')
                    sid_end = sc_json.find('"', sid_start)
                    if sid_end != -1 and sid_start > len('"id":"'):
                        resource_scope_ids.append(sc_json[sid_start:sid_end])
                    sc_json = sc_json[sid_end + 1:]

            # Validate and collect provided scope ids
            for scope_name in scopes:
                sc_url = auth_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/scope?name=" + scope_name
                sc_res2 = ctx.run(
                    [
                        "curl",
                        "-s", "-S",
                        "-H", "Authorization: " + auth_header,
                        sc_url
                    ],
                    ok_codes=[0]
                )
                if sc_res2.skipped:
                    fail("Scope lookup skipped in check_mode")
                if sc_res2.rc != 0:
                    fail("Failed to lookup scope: " + sc_res2.stderr)
                sc2_json = sc_res2.stdout.strip()
                if sc2_json == "[]" or len(sc2_json) == 0:
                    fail("Unable to find authorization scope with name %s for client %s in realm %s" % (scope_name, client_id, realm))
                # Extract id
                sid_start2 = sc2_json.find('"id":"') + len('"id":"')
                sid_end2 = sc2_json.find('"', sid_start2)
                if sid_end2 != -1 and sid_start2 > len('"id":"'):
                    sid = sc2_json[sid_start2:sid_end2]
                else:
                    fail("Failed to extract scope id")
                if len(resource_scope_ids) > 0 and sid not in resource_scope_ids:
                    fail("Resource %s does not include scope %s for client %s in realm %s" % (resources[0], scope_name, client_id, realm))
                payload["scopes"].append(sid)

    elif permission_type == "resource":
        for res_name in resources:
            r_url2 = auth_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/resource?name=" + res_name
            r_res2 = ctx.run(
                [
                    "curl",
                    "-s", "-S",
                    "-H", "Authorization: " + auth_header,
                    r_url2
                ],
                ok_codes=[0]
            )
            if r_res2.skipped:
                fail("Resource lookup skipped in check_mode")
            if r_res2.rc != 0:
                fail("Failed to lookup resource: " + r_res2.stderr)
            r_json2 = r_res2.stdout.strip()
            if r_json2 == "[]" or len(r_json2) == 0:
                fail("Unable to find authorization resource with name %s for client %s in realm %s" % (res_name, client_id, realm))
            rid_start2 = r_json2.find('"_id":"') + len('"_id":"')
            rid_end2 = r_json2.find('"', rid_start2)
            if rid_end2 != -1 and rid_start2 > len('"_id":"'):
                rid = r_json2[rid_start2:rid_end2]
            else:
                fail("Failed to extract resource id")
            payload["resources"].append(rid)

    # Resolve policies
    for pol_name in policies:
        pol_url = auth_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/policy?name=" + pol_name
        pol_res = ctx.run(
            [
                "curl",
                "-s", "-S",
                "-H", "Authorization: " + auth_header,
                pol_url
            ],
            ok_codes=[0]
        )
        if pol_res.skipped:
            fail("Policy lookup skipped in check_mode")
        if pol_res.rc != 0:
            fail("Failed to lookup policy: " + pol_res.stderr)
        pol_json = pol_res.stdout.strip()
        if pol_json == "[]" or len(pol_json) == 0:
            fail("Unable to find authorization policy with name %s for client %s in realm %s" % (pol_name, client_id, realm))
        # Extract id
        pid_start = pol_json.find('"id":"') + len('"id":"')
        pid_end = pol_json.find('"', pid_start)
        if pid_end != -1 and pid_start > len('"id":"'):
            pid = pol_json[pid_start:pid_end]
        else:
            fail("Failed to extract policy id")
        payload["policies"].append(pid)

    # Handle state
    if state == "present":
        if permission != None:
            # Check if type changed
            if permission["type"] != permission_type:
                fail("Modifying the type of permission (scope/resource) is not supported: permission unchanged")
            # In check_mode: report change required
            if ctx.check_mode:
                return {
                    "changed": True,
                    "msg": "Notice: unable to check current resources, scopes and policies for permission. Would apply desired state without checking the current state."
                }
            # Update payload with id
            payload["id"] = permission["id"]
            update_url = auth_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/permission/" + permission_type + "/" + permission["id"]
            update_data = str(payload).replace("'", '"').replace("True", "true").replace("False", "false")  # naive JSON conversion
            update_res = ctx.run(
                [
                    "curl",
                    "-s", "-S",
                    "-X", "PUT",
                    "-H", "Authorization: " + auth_header,
                    "-H", "Content-Type: application/json",
                    "-d", update_data,
                    update_url
                ],
                ok_codes=[0, 204]
            )
            if update_res.skipped:
                return {
                    "changed": True,
                    "msg": "Notice: unable to check current resources, scopes and policies for permission. Would apply desired state without checking the current state."
                }
            if update_res.rc != 0:
                fail("Failed to update permission: " + update_res.stderr)
            return {
                "changed": True,
                "msg": "Notice: unable to check current resources, scopes and policies for permission. Applying desired state without checking the current state.",
                "data": payload
            }
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "Would create permission"}
            create_url = auth_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/permission/" + permission_type
            create_data = str(payload).replace("'", '"').replace("True", "true").replace("False", "false")
            create_res = ctx.run(
                [
                    "curl",
                    "-s", "-S",
                    "-X", "POST",
                    "-H", "Authorization: " + auth_header,
                    "-H", "Content-Type: application/json",
                    "-d", create_data,
                    create_url
                ],
                ok_codes=[0, 201]
            )
            if create_res.skipped:
                return {"changed": True, "msg": "Would create permission"}
            if create_res.rc != 0:
                fail("Failed to create permission: " + create_res.stderr)
            return {
                "changed": True,
                "msg": "Permission created",
                "data": payload
            }
    elif state == "absent":
        if permission != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "Would remove permission"}
            delete_url = auth_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/permission/" + permission_type + "/" + permission["id"]
            delete_res = ctx.run(
                [
                    "curl",
                    "-s", "-S",
                    "-X", "DELETE",
                    "-H", "Authorization: " + auth_header,
                    delete_url
                ],
                ok_codes=[0, 204]
            )
            if delete_res.skipped:
                return {"changed": True, "msg": "Would remove permission"}
            if delete_res.rc != 0:
                fail("Failed to delete permission: " + delete_res.stderr)
            return {
                "changed": True,
                "msg": "Permission removed"
            }
        else:
            return {
                "changed": False,
                "msg": "Permission not found"
            }
    fail("Unable to determine what to do with permission")
