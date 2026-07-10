def main(ctx, params):
    # Required auth parameters
    auth_url = params["auth_keycloak_url"]
    realm = params.get("realm", "master")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_realm = params.get("auth_realm")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Module parameters
    state = params.get("state", "present")
    name = params.get("name")
    cid = params.get("id")
    description = params.get("description")
    protocol = params.get("protocol")
    attributes = params.get("attributes")
    protocol_mappers = params.get("protocol_mappers")

    # Validate required params for create/update
    if state == "present" and name == None:
        fail("name is required when state is present")

    # Build authentication header
    auth_header = ""
    if token != None:
        auth_header = "Bearer %s" % token
    elif auth_username != None and auth_password != None and auth_realm != None:
        # Fetch token via password grant
        payload = (
            "client_id=%s&username=%s&password=%s&grant_type=password"
            % (auth_client_id, auth_username, auth_password)
        )
        if auth_realm != None:
            payload += "&realm=" + auth_realm

        res = ctx.run(
            [
                "curl",
                "-s",
                "-X",
                "POST",
                "-H",
                "Content-Type: application/x-www-form-urlencoded",
                "-d",
                payload,
                auth_url.rstrip("/") + "/realms/master/protocol/openid-connect/token",
            ],
            mutates=False,
        )
        if res.rc != 0:
            fail("failed to obtain token: " + res.stderr)
        # Extract access_token from JSON response
        token_val = ""
        start = res.stdout.find('"access_token":"')
        if start >= 0:
            start += len('"access_token":"')
            end = res.stdout.find('"', start)
            if end > start:
                token_val = res.stdout[start:end]
        if token_val == "":
            fail("failed to parse access_token from response")
        auth_header = "Bearer %s" % token_val
    else:
        fail("token or auth_username/auth_password/auth_realm is required")

    headers = [
        "-H",
        "Authorization: %s" % auth_header,
        "-H",
        "Content-Type: application/json",
        "-H",
        "User-Agent: %s" % http_agent,
        "--connect-timeout",
        str(connection_timeout),
    ]
    if not validate_certs:
        headers += ["-k"]

    # Parse simple JSON fields
    def parse_json_str_field(json_str, field):
        start = json_str.find('"%s":"' % field)
        if start == -1:
            start = json_str.find('"%s": "' % field)
        if start == -1:
            return ""
        start += len('"%s":"' % field)
        end = json_str.find('"', start)
        if end > start:
            return json_str[start:end]
        return ""

    def parse_json_str(json_str):
        result = {}
        result["id"] = parse_json_str_field(json_str, "id")
        result["name"] = parse_json_str_field(json_str, "name")
        result["description"] = parse_json_str_field(json_str, "description")
        result["protocol"] = parse_json_str_field(json_str, "protocol")
        result["attributes"] = {}
        return result

    # Fetch existing clientscope by name or id
    def get_clientscope():
        if cid != None:
            url = auth_url.rstrip("/") + "/admin/realms/%s/client-scopes/%s" % (
                realm,
                cid,
            )
            res = ctx.run(
                ["curl", "-s"] + headers + [url],
                mutates=False,
            )
            if res.rc == 404:
                return {}
            if res.rc != 0:
                fail("failed to get client scope: " + res.stderr)
            return parse_json_str(res.stdout)
        elif name != None:
            url = auth_url.rstrip("/") + "/admin/realms/%s/client-scopes?search=%s" % (
                realm,
                name,
            )
            res = ctx.run(
                ["curl", "-s"] + headers + [url],
                mutates=False,
            )
            if res.rc != 0:
                fail("failed to list client scopes: " + res.stderr)
            # Extract first JSON object matching name
            # Find first '{'
            pos = res.stdout.find("{")
            if pos == -1:
                return {}
            # Find matching '}'
            brace_count = 0
            end = pos
            for i in range(pos, len(res.stdout)):
                if res.stdout[i] == "{":
                    brace_count += 1
                elif res.stdout[i] == "}":
                    brace_count -= 1
                    if brace_count == 0:
                        end = i + 1
                        break
            obj_str = res.stdout[pos:end]
            # Check if it has matching name
            name_val = parse_json_str_field(obj_str, "name")
            if name_val == name:
                return parse_json_str(obj_str)
            return {}
        else:
            return {}

    before = get_clientscope()
    if before == None:
        before = {}

    # Build desired representation
    desired = {}
    if before != {}:
        desired = before.copy()

    if name != None:
        desired["name"] = name
    if description != None:
        desired["description"] = description
    if protocol != None:
        desired["protocol"] = protocol
    if attributes != None:
        desired["attributes"] = attributes
    if protocol_mappers != None:
        desired["protocolMappers"] = protocol_mappers

    # Determine if change needed
    changed = False

    # Compare desired vs existing (simplified)
    if before == {}:
        if state == "absent":
            return {"changed": False, "msg": "Client scope does not exist; doing nothing."}
        # Create needed
        changed = True
    else:
        # Compare fields (excluding auto-generated fields)
        for k in desired:
            if k in ["id"]:
                continue
            if desired.get(k) != before.get(k):
                changed = True
                break

    if state == "absent":
        if before == {}:
            return {"changed": False, "msg": "Client scope does not exist; doing nothing."}
        changed = True

    if not changed and state == "present":
        return {"changed": False, "msg": "No changes required."}

    # Handle check_mode
    if ctx.check_mode:
        return {
            "changed": changed,
            "msg": "would " + ("delete" if state == "absent" else "update/create") + " client scope",
        }

    # Execute change
    if state == "present":
        if before == {}:
            # Create
            url = auth_url.rstrip("/") + "/admin/realms/%s/client-scopes" % realm
            # Build JSON payload (simplified)
            payload = "{"
            if "name" in desired:
                payload += '"name":"%s",' % desired["name"]
            if "description" in desired:
                payload += '"description":"%s",' % desired["description"]
            if "protocol" in desired:
                payload += '"protocol":"%s",' % desired["protocol"]
            if "attributes" in desired:
                attrs = desired["attributes"]
                payload += '"attributes":{'
                first = True
                for k, v in attrs.items():
                    if first != True:
                        payload += ","
                    payload += '"%s":"%s"' % (k, v)
                    first = False
                payload += "},"
            if "protocolMappers" in desired:
                mappers = desired["protocolMappers"]
                payload += '"protocolMappers":['
                for i in range(len(mappers)):
                    if i > 0:
                        payload += ","
                    mapper = mappers[i]
                    payload += "{"
                    for k, v in mapper.items():
                        payload += '"%s":"%s",' % (k, v)
                    payload = payload.rstrip(",") + "}"
                payload += "]"
            payload += "}"

            res = ctx.run(
                ["curl", "-s", "-X", "POST"] + headers + ["-d", payload, url],
                mutates=True,
            )
            if res.rc != 0:
                fail("failed to create client scope: " + res.stderr)

            # Extract ID from response
            created_id = parse_json_str_field(res.stdout, "id")
            return {
                "changed": True,
                "msg": "Client scope %s has been created with ID %s" % (name, created_id),
            }
        else:
            # Update
            url = auth_url.rstrip("/") + "/admin/realms/%s/client-scopes/%s" % (realm, before["id"])
            # Build update payload (only send changed fields)
            payload = "{"
            if "name" in desired:
                payload += '"name":"%s",' % desired["name"]
            if "description" in desired:
                payload += '"description":"%s",' % desired["description"]
            if "protocol" in desired:
                payload += '"protocol":"%s",' % desired["protocol"]
            if "attributes" in desired:
                attrs = desired["attributes"]
                payload += '"attributes":{'
                first = True
                for k, v in attrs.items():
                    if first != True:
                        payload += ","
                    payload += '"%s":"%s"' % (k, v)
                    first = False
                payload += "},"
            if "protocolMappers" in desired:
                mappers = desired["protocolMappers"]
                payload += '"protocolMappers":['
                for i in range(len(mappers)):
                    if i > 0:
                        payload += ","
                    mapper = mappers[i]
                    payload += "{"
                    for k, v in mapper.items():
                        payload += '"%s":"%s",' % (k, v)
                    payload = payload.rstrip(",") + "}"
                payload += "]"
            payload += "}"

            res = ctx.run(
                ["curl", "-s", "-X", "PUT"] + headers + ["-d", payload, url],
                mutates=True,
            )
            if res.rc != 0:
                fail("failed to update client scope: " + res.stderr)

            return {
                "changed": True,
                "msg": "Client scope %s has been updated" % before["id"],
            }

    elif state == "absent":
        if before == {}:
            return {"changed": False, "msg": "Client scope does not exist; doing nothing."}
        url = auth_url.rstrip("/") + "/admin/realms/%s/client-scopes/%s" % (realm, before["id"])
        res = ctx.run(
            ["curl", "-s", "-X", "DELETE"] + headers + [url],
            mutates=True,
        )
        if res.rc != 0:
            fail("failed to delete client scope: " + res.stderr)
        return {
            "changed": True,
            "msg": "Client scope %s has been deleted" % before.get("name", before.get("id", "")),
        }

    fail("unexpected state")
