def main(ctx, params):
    baseuri = params["baseuri"]
    category = params["category"]
    command_list = params["command"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    timeout = str(params.get("timeout", 10))

    # Validate required combinations
    if username == None and auth_token == None:
        fail("one of username or auth_token is required")
    if username != None and auth_token != None:
        fail("username and auth_token are mutually exclusive")
    if username != None and password == None:
        fail("password is required when username is provided")

    # Valid categories and commands
    valid_categories = {"Manager": ["GetManagerAttributes"]}
    if category not in valid_categories:
        fail("Invalid Category '" + category + "'. Valid Categories = " + str(list(valid_categories.keys())))

    for cmd in command_list:
        if cmd not in valid_categories[category]:
            fail("Invalid Command '" + cmd + "'. Valid Commands = " + str(valid_categories[category]))

    root_uri = "https://" + baseuri
    manager_uri = "/redfish/v1/Managers/iDRAC.Embedded.1"

    # Check Mode: probe current state for GetManagerAttributes (read-only)
    if ctx.check_mode:
        # Only GetManagerAttributes is supported; probe its existence
        if category == "Manager" and "GetManagerAttributes" in command_list:
            res = ctx.run(
                ["curl", "-s", "-k", "-f", "-X", "GET", root_uri + manager_uri],
                mutates=False,
                ok_codes=[0, 404]
            )
            if res.rc == 404:
                return {"changed": False, "msg": "iDRAC Manager not found", "data": {"entries": []}}
            if res.rc != 0:
                fail("failed to probe iDRAC Manager: " + res.stderr)
            # In check_mode, predict a successful retrieval
            return {
                "changed": False,
                "msg": "iDRAC Manager attributes would be retrieved",
                "data": {"entries": [{"Id": "iDRACAttributes", "Attributes": {}}]}
            }

    # Auth header setup
    headers = ["-H", "Accept: application/json", "-H", "Content-Type: application/json"]
    if auth_token != None:
        headers += ["-H", "X-Auth-Token: " + auth_token]
    else:
        headers += ["-u", username + ":" + password]

    # Execute GetManagerAttributes
    if category == "Manager":
        # Step 1: get Manager resource to find attributes URIs
        res = ctx.run(
            ["curl", "-s", "-k", "-f"] + headers + [root_uri + manager_uri],
            mutates=False,
            ok_codes=[0]
        )
        if res.rc != 0:
            fail("failed to retrieve iDRAC Manager resource: " + res.stderr)

        # Parse manager JSON to extract attributes URIs
        manager_data = res.stdout
        # Simple JSON extraction of Links.Oem.Dell.DellAttributes array
        # Look for pattern: "DellAttributes": [ { "@odata.id": "..." }, ... ]
        attributes_uris = []
        # naive extraction: find all "@odata.id" inside DellAttributes block
        # Assume structure is well-formed and avoid full JSON parser (no json in Starlark)
        # We'll search for lines containing "@odata.id" and collect strings
        lines = manager_data.split("\n")
        in_dell_attrs = False
        for line in lines:
            stripped = line.strip()
            if '"DellAttributes"' in stripped:
                in_dell_attrs = True
            if in_dell_attrs and '"@odata.id"' in stripped:
                # extract value: find quotes
                start = stripped.find('"@odata.id"')
                if start != -1:
                    rest = stripped[start + len('"@odata.id"'):]
                    colon = rest.find(":")
                    if colon != -1:
                        val = rest[colon + 1:].strip()
                        if val.startswith('"') and val.endswith('"'):
                            uri = val[1:-1]
                            attributes_uris.append(uri)
            # Exit if we left the array (simple heuristic)
            if in_dell_attrs and stripped == "]" and not line.strip().startswith('"'):
                in_dell_attrs = False

        # Step 2: fetch each attributes URI
        manager_attributes = []
        for attr_uri in attributes_uris:
            res = ctx.run(
                ["curl", "-s", "-k", "-f"] + headers + [root_uri + attr_uri],
                mutates=False,
                ok_codes=[0]
            )
            if res.rc != 0:
                fail("failed to retrieve attributes from " + attr_uri + ": " + res.stderr)
            attr_data = res.stdout
            # Extract Id and Attributes if present in JSON
            # Very simple extraction: look for "Id":"..." and "Attributes":{...}
            # This is heuristic and may fail on malformed responses; fail() if not found
            id_val = ""
            attrs_json = ""
            # naive Id extraction
            id_key = '"Id"'
            idx = attr_data.find(id_key)
            if idx != -1:
                rest = attr_data[idx + len(id_key):]
                colon = rest.find(":")
                if colon != -1:
                    val = rest[colon + 1:].strip()
                    if val.startswith('"'):
                        end = val.find('"', 1)
                        if end != -1:
                            id_val = val[1:end]
            # naive Attributes extraction
            attrs_key = '"Attributes"'
            idx = attr_data.find(attrs_key)
            if idx != -1:
                rest = attr_data[idx + len(attrs_key):]
                colon = rest.find(":")
                if colon != -1:
                    brace = rest.find("{", colon)
                    if brace != -1:
                        # find matching } – simple heuristic: take until last }
                        # for simplicity, we take until } that closes outermost { (naive)
                        depth = 0
                        end_brace = -1
                        for i in range(brace, len(rest)):
                            if rest[i] == '{':
                                depth += 1
                            elif rest[i] == '}':
                                depth -= 1
                                if depth == 0:
                                    end_brace = i + 1
                                    break
                        if end_brace != -1:
                            attrs_json = rest[brace:end_brace]
                        else:
                            attrs_json = "{}"

            # Build entry dict
            entry = {}
            if id_val != "":
                entry["Id"] = id_val
            if attrs_json != "" and attrs_json != "{}":
                # store Attributes as JSON string (Starlark has no dict literal from string)
                # We'll store the raw string as "Attributes"; caller may parse externally
                entry["Attributes"] = attrs_json

            if entry != {}:
                manager_attributes.append(entry)

        return {
            "changed": False,
            "msg": "Retrieved Manager attributes",
            "data": {"entries": manager_attributes}
        }

    fail("unsupported category/command combination")
