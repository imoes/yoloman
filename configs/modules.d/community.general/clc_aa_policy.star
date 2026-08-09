def main(ctx, params):
    location = params["location"]
    name = params["name"]
    state = params.get("state", "present")

    # Environment variables for CLC credentials
    v2_api_token = ctx.facts().get("env", {}).get("CLC_V2_API_TOKEN") if hasattr(ctx, "facts") else None
    v2_api_username = ctx.facts().get("env", {}).get("CLC_V2_API_USERNAME") if hasattr(ctx, "facts") else None
    v2_api_passwd = ctx.facts().get("env", {}).get("CLC_V2_API_PASSWD") if hasattr(ctx, "facts") else None
    clc_alias = ctx.facts().get("env", {}).get("CLC_ACCT_ALIAS") if hasattr(ctx, "facts") else None
    api_url = ctx.facts().get("env", {}).get("CLC_V2_API_URL") if hasattr(ctx, "facts") else None

    # Fail if required environment variables not set (we can't rely on facts() for env, so fallback to ctx.run)
    # Since Starlark has no os.environ, we rely on a custom fact or fail if missing.
    # To keep it simple: we'll try to run a read-only API command to detect auth.
    # If neither token nor username+pass are provided, fail early.
    if not (v2_api_token and clc_alias) and not (v2_api_username and v2_api_passwd):
        fail("You must set the CLC_V2_API_USERNAME and CLC_V2_API_PASSWD or CLC_V2_API_TOKEN and CLC_ACCT_ALIAS environment variables")

    # Try to set API URL if provided
    if api_url:
        # This would be done via the SDK in original Python, but we can't simulate SDK calls.
        # We proceed assuming the SDK would be configured. Starlark can't call CLC SDK directly.
        # Therefore, we simulate via a CLI or API call — but no CLI exists, so we use HTTP.
        pass  # No action possible in Starlark without HTTP client. We'll use ctx.run only.

    # Use HTTP directly to interact with CLC API (no SDK in Starlark)
    base_url = api_url.rstrip("/") if api_url else "https://api.ctl.io/v2"
    auth_url = base_url + "/authentication/login"

    # If token not available, generate it
    token = v2_api_token
    if not token:
        if not (v2_api_username and v2_api_passwd):
            fail("Missing credentials: need CLC_V2_API_USERNAME and CLC_V2_API_PASSWD")
        # Generate token via HTTP POST
        payload = '{"userName":"%s","password":"%s"}' % (v2_api_username, v2_api_passwd)
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", payload, auth_url],
            mutates=False
        )
        if res.rc != 0:
            fail("Failed to authenticate: " + res.stderr)
        # Parse JSON manually (Starlark has no json module)
        # Expect {"apiToken":"..."}
        token = _extract_token(res.stdout)
        if not token:
            fail("Failed to parse API token from login response")

    # Set default account alias for API paths
    account = clc_alias
    if not account:
        # Try to get alias from token — not possible without SDK; fallback fail.
        fail("CLC_ACCT_ALIAS is required and must be set as environment variable")

    # Build API endpoints
    policies_url = "%s/antiAffinityPolicies/%s" % (base_url, account)
    datacenter_url = policies_url + "/%s" % location

    # Probe existing policies
    res = ctx.run(
        ["curl", "-s", "-H", "Content-Type: application/json", "-H", "Authorization: Bearer " + token, datacenter_url],
        mutates=False
    )
    if res.rc != 0:
        fail("Failed to list anti-affinity policies: " + res.stderr)

    # Parse JSON manually
    existing_policies = _parse_policies(res.stdout)

    policy_exists = name in existing_policies

    if state == "absent":
        if not policy_exists:
            return {"changed": False, "msg": "Policy '%s' not found in location '%s'" % (name, location)}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete policy '%s'" % name}
        # Delete policy
        policy_id = existing_policies[name]
        delete_url = "%s/%s" % (datacenter_url, policy_id)
        res = ctx.run(
            ["curl", "-s", "-X", "DELETE", "-H", "Content-Type: application/json", "-H", "Authorization: Bearer " + token, delete_url],
            mutates=True
        )
        if res.rc != 0:
            fail("Failed to delete policy: " + res.stderr)
        return {"changed": True, "msg": "Deleted policy '%s'" % name}

    else:  # state == "present"
        if policy_exists:
            return {"changed": False, "msg": "Policy '%s' already exists" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would create policy '%s' in location '%s'" % (name, location)}
        # Create policy
        create_url = datacenter_url
        payload = '{"name":"%s"}' % name
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-H", "Authorization: Bearer " + token, "-d", payload, create_url],
            mutates=True
        )
        if res.rc != 0:
            fail("Failed to create policy: " + res.stderr)
        # Extract ID from response
        created = _parse_policy_response(res.stdout)
        if not created:
            fail("Failed to parse policy ID from creation response")
        return {"changed": True, "msg": "Created policy '%s' (id: %s)" % (name, created), "data": {"id": created, "name": name, "location": location}}


# Helper: extract API token from JSON login response
def _extract_token(output):
    # Very naive JSON parser for {"apiToken":"<token>"}
    for line in output.split("\n"):
        stripped = line.strip()
        if stripped.startswith("{") and stripped.endswith("}"):
            # Split on commas and quotes
            for part in stripped.split(","):
                part = part.strip()
                if '"apiToken"' in part:
                    # Extract value between quotes after colon
                    parts = part.split(":")
                    if len(parts) >= 2:
                        val = parts[1].strip().strip('"')
                        if val and not val.startswith("{"):
                            return val
    return None


# Helper: parse list of policies from GET response
def _parse_policies(output):
    # Output is list of dicts: [{"id":"...", "name":"..."}, ...]
    result = {}
    # Strip outer brackets and split by '}, {' pattern
    text = output.strip()
    if not text.startswith("[") or not text.endswith("]"):
        fail("Unexpected policy list format")
    text = text[1:-1].strip()
    if not text:
        return result
    # Split into policy objects — naive
    # Replace '}, {' with '}\n{'
    text = text.replace("}, {", "}\n{")
    # Now split on newline
    items = [item.strip() for item in text.split("\n") if item.strip()]
    for item in items:
        if not item.startswith("{"):
            item = "{" + item
        if not item.endswith("}"):
            item = item + "}"
        policy_id = _json_get(item, "id")
        policy_name = _json_get(item, "name")
        if policy_id and policy_name:
            result[policy_name] = policy_id
    return result


# Helper: parse single policy creation response
def _parse_policy_response(output):
    # Expect {"id":"...", "name":"...", ...}
    return _json_get(output.strip(), "id")


# Simple JSON field extractor (assumes well-formed JSON with double quotes)
def _json_get(json_str, key):
    # Look for '"key": "value"' or '"key":"value"'
    search = '"' + key + '":'
    idx = json_str.find(search)
    if idx == -1:
        return None
    start = idx + len(search)
    rest = json_str[start:].strip()
    # Remove leading whitespace and quotes
    if rest.startswith('"'):
        rest = rest[1:]
        end = rest.find('"')
        if end == -1:
            return None
        return rest[:end]
    # Fallback for numbers/booleans — but ID is string
    return None
