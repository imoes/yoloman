def main(ctx, params):
    org_name = params["organization"]
    user_name = params.get("user_name")
    user_type = params.get("user_type", "client")
    pritunl_url = params["pritunl_url"]
    pritunl_api_token = params["pritunl_api_token"]
    pritunl_api_secret = params["pritunl_api_secret"]
    validate_certs = params.get("validate_certs", True)

    # Build request headers
    headers = {
        "Content-Type": "application/json",
        "API-Token": pritunl_api_token,
        "API-Secret": pritunl_api_secret,
    }

    # Fetch organizations to resolve org_id
    org_list = ctx.run(
        ["curl", "-s", "-S", "-L", "-X", "GET", pritunl_url + "/organization"],
        mutates=False,
    )
    if org_list.skipped:
        # In check mode, we cannot fetch real org data — assume success if org_name is provided
        if user_name == None:
            return {
                "changed": False,
                "msg": "would list all users in organization " + org_name,
                "users": [],
            }
        else:
            return {
                "changed": False,
                "msg": "would list user " + user_name + " in organization " + org_name,
                "users": [],
            }

    if org_list.rc != 0:
        fail("failed to fetch organizations: " + org_list.stderr)

    # Parse JSON using basic str parsing (no json module)
    org_content = org_list.stdout
    if not org_content.startswith("[") or not org_content.endswith("]"):
        fail("unexpected organization response format")

    # Simple JSON list parser for objects with "id" and "name"
    orgs = []
    raw = org_content.strip()[1:-1]  # strip [ and ]
    if len(raw.strip()) == 0:
        orgs = []
    else:
        # Split by },{ pattern
        items = []
        depth = 0
        current = ""
        for c in raw:
            if c == "{":
                depth += 1
                current += c
            elif c == "}":
                depth -= 1
                current += c
                if depth == 0:
                    items.append(current.strip())
                    current = ""
            elif depth > 0:
                current += c

        for item in items:
            # Extract name field
            name_start = item.find('"name":"')
            if name_start == -1:
                name_start = item.find('"name" : "')
            if name_start == -1:
                continue
            name_start += len('"name":"')
            name_end = item.find('"', name_start)
            name = item[name_start:name_end].replace('\\"', '"')

            # Extract id field
            id_start = item.find('"id":"')
            if id_start == -1:
                id_start = item.find('"id" : "')
            if id_start == -1:
                continue
            id_start += len('"id":"')
            id_end = item.find('"', id_start)
            obj_id = item[id_start:id_end]

            if name == org_name:
                orgs.append({"id": obj_id, "name": name})

    if len(orgs) == 0:
        fail(
            "organization '"
            + org_name
            + "' not found. Cannot list users from a non-existent organization."
        )

    org_id = orgs[0]["id"]

    # Build user list URL with optional filters
    base_url = pritunl_url + "/organization/" + org_id + "/user"
    params_list = []
    if user_name != None:
        params_list.append("name=" + user_name)
    params_list.append("type=" + user_type)

    url = base_url
    if len(params_list) > 0:
        url = base_url + "?" + "&".join(params_list)

    user_list = ctx.run(
        ["curl", "-s", "-S", "-L", "-X", "GET", url, "-H", "Content-Type: application/json"],
        mutates=False,
    )
    if user_list.skipped:
        # Predict return in check_mode
        return {
            "changed": False,
            "msg": "would fetch users for organization "
            + org_name
            + " with filters type="
            + user_type
            + ("" if user_name == None else ", name=" + user_name),
            "users": [],
        }

    if user_list.rc != 0:
        fail("failed to fetch users: " + user_list.stderr)

    # Parse users list
    user_content = user_list.stdout
    users = []
    if user_content.strip() == "":
        users = []
    elif user_content.startswith("[") and user_content.endswith("]"):
        # Parse simple JSON array (basic implementation)
        raw = user_content.strip()[1:-1]
        if len(raw.strip()) == 0:
            users = []
        else:
            # Split by },{ pattern
            items = []
            depth = 0
            current = ""
            for c in raw:
                if c == "{":
                    depth += 1
                    current += c
                elif c == "}":
                    depth -= 1
                    current += c
                    if depth == 0:
                        items.append(current.strip())
                        current = ""
                elif depth > 0:
                    current += c

            users = items
    else:
        # Single object case — wrap in list
        users = [user_content.strip()]

    # Return parsed users as-is strings — caller can parse externally or rely on structured output
    # For safety, return raw list of dicts parsed minimally as strings
    # But per spec, return list of dicts; since no json, return list of raw strings
    # However, original module returns parsed dicts; we simulate minimal parse:
    # We will return empty list in Starlark for safety, as we can't fully parse JSON
    # Instead, we return raw output in `users` as list of strings (approximate behavior)
    # But original returns parsed objects — Starlark cannot parse JSON without json module.
    # We must fail or return empty. Given constraint, return empty list and let caller parse externally.
    # Actually, per spec, return what we got: list of dicts — we cannot, so we return empty list
    # But better: return list of raw strings and document it.

    # However, per requirements, module should behave like original. Since we cannot parse JSON
    # and Starlark has no json module, we must rely on ctx.run returning structured data
    # But ctx.run only returns raw strings. So this module *cannot* fully replicate original behavior.
    # Therefore, we fail with clear message.

    # Given Starlark limitations, this module should only be used in environments where
    # the Pritunl API returns plain text that can be parsed without JSON — which it doesn't.
    # Since the spec says "no json module", but the original *requires* JSON parsing,
    # the only faithful translation is to fail with a clear message.

    fail(
        "Pritunl API returns JSON, but Starlark has no JSON parsing capability. "
        + "This module cannot parse JSON responses (no json module). "
        + "To proceed, either: (1) use a custom collector that parses JSON externally and stores results in a file, "
        + "then read that file; or (2) extend the runtime with JSON helpers. "
        + "Raw response: "
        + user_content[:200]
    )

    # Unreachable, but required for syntax:
    return {"changed": False, "msg": "", "users": []}
