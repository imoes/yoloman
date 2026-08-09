def main(ctx, params):
    # Extract parameters
    realm = params.get("realm", "master")
    client_id = params.get("client_id")
    default_clientscopes = params.get("default_clientscopes")
    optional_clientscopes = params.get("optional_clientscopes")

    # Validate required inputs
    token = params.get("token")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_realm = params.get("auth_realm")
    auth_keycloak_url = params.get("auth_keycloak_url")

    # Auth validation: either token or all auth_* fields
    if token == None and (auth_username == None or auth_password == None or auth_realm == None):
        fail("Either 'token' or 'auth_username', 'auth_password', and 'auth_realm' must be provided")

    if token != None and auth_username != None:
        fail("Cannot use both 'token' and 'auth_username'")

    if token != None and auth_password != None:
        fail("Cannot use both 'token' and 'auth_password'")

    if token != None and auth_realm != None:
        fail("Cannot use both 'token' and 'auth_realm'")

    if auth_keycloak_url == None:
        fail("'auth_keycloak_url' is required")

    # Build base URL for Keycloak admin API
    base_url = auth_keycloak_url.rstrip("/")
    if not base_url.endswith("/auth"):
        base_url = base_url + "/auth"
    api_base = base_url + "/admin/realms/" + realm

    # Auth: get token via username/password or use provided token
    def get_token():
        if token != None:
            return token
        # Build token URL
        token_url = base_url + "/realms/" + auth_realm + "/protocol/openid-connect/token"
        # Prepare POST body
        body = (
            "client_id=" + params.get("auth_client_id", "admin-cli") +
            "&username=" + auth_username +
            "&password=" + auth_password +
            "&grant_type=password"
        )
        if params.get("auth_client_secret") != None:
            body += "&client_secret=" + params.get("auth_client_secret")

        headers = [
            "Content-Type: application/x-www-form-urlencoded",
            "User-Agent: Ansible"
        ]
        curl_args = ["curl", "-s", "-X", "POST", token_url, "-d", body]
        for h in headers:
            curl_args.extend(["-H", h])
        if params.get("validate_certs", True) == False:
            curl_args.append("-k")
        res = ctx.run(curl_args, mutates=False)
        if res.rc != 0:
            fail("Failed to authenticate: " + res.stderr)
        # Parse JSON response manually (no json module)
        stdout = res.stdout
        # Simple extraction: look for "access_token":"..."" pattern
        token_start = stdout.find('"access_token":"')
        if token_start == -1:
            fail("Could not extract access token from response")
        token_start += len('"access_token":"')
        token_end = stdout.find('"', token_start)
        if token_end == -1:
            fail("Could not extract access token from response")
        return stdout[token_start:token_end]

    # Helper to make HTTP requests with auth header
    def request(method, path, ok_codes=None):
        if ok_codes == None:
            ok_codes = [200]
        url = api_base + "/" + path.lstrip("/")
        auth_header = "Authorization: Bearer " + get_token()
        curl_args = ["curl", "-s", "-X", method]
        if params.get("validate_certs", True) == False:
            curl_args.append("-k")
        curl_args.extend(["-H", auth_header, "-H", "User-Agent: " + params.get("http_agent", "Ansible")])
        curl_args.append(url)
        res = ctx.run(curl_args, mutates=(method != "GET"))
        if res.rc not in ok_codes:
            fail("HTTP " + method + " failed to " + url + ": " + res.stderr)
        return res

    # Helper to get JSON list
    def get_json_list(path):
        res = request("GET", path)
        return parse_json_array(res.stdout)

    # Simple JSON array parser
    def parse_json_array(s):
        s = s.strip()
        if s == "[]":
            return []
        if not s.startswith("[") or not s.endswith("]"):
            return []
        inner = s[1:-1].strip()
        if not inner:
            return []
        result = []
        depth = 0
        current = []
        in_string = False
        i = 0
        while i < len(inner):
            c = inner[i]
            if c == '"' and (i == 0 or inner[i - 1] != '\\'):
                in_string = not in_string
                current.append(c)
            elif not in_string:
                if c == '{':
                    depth += 1
                    current.append(c)
                elif c == '}':
                    depth -= 1
                    current.append(c)
                    if depth == 0:
                        result.append("".join(current))
                        current = []
                elif c == ',' and depth == 0:
                    if "".join(current).strip():
                        result.append("".join(current).strip())
                    current = []
                else:
                    current.append(c)
            else:
                current.append(c)
            i += 1
        if "".join(current).strip():
            result.append("".join(current).strip())
        dicts = []
        for obj in result:
            dicts.append(parse_json_object(obj))
        return dicts

    def parse_json_object(s):
        s = s.strip()
        if not (s.startswith("{") and s.endswith("}")):
            return {}
        inner = s[1:-1].strip()
        if not inner:
            return {}
        pairs = []
        depth = 0
        in_string = False
        current = []
        i = 0
        while i < len(inner):
            c = inner[i]
            if c == '"' and (i == 0 or inner[i - 1] != '\\'):
                in_string = not in_string
                current.append(c)
            elif not in_string:
                if c == '{' or c == '[':
                    depth += 1
                    current.append(c)
                elif c == '}' or c == ']':
                    depth -= 1
                    current.append(c)
                elif c == ',' and depth == 0:
                    if "".join(current).strip():
                        pairs.append("".join(current).strip())
                    current = []
                else:
                    current.append(c)
            else:
                current.append(c)
            i += 1
        if "".join(current).strip():
            pairs.append("".join(current).strip())
        obj = {}
        for pair in pairs:
            if ':' not in pair:
                continue
            colon = pair.find(':')
            key_str = pair[:colon].strip()
            val_str = pair[colon + 1:].strip()
            if key_str.startswith('"') and key_str.endswith('"'):
                key_str = key_str[1:-1]
            val = parse_json_value(val_str)
            obj[key_str] = val
        return obj

    def parse_json_value(s):
        s = s.strip()
        if s.startswith('"') and s.endswith('"'):
            inner = s[1:-1]
            return inner.replace('\\"', '"').replace('\\\\', '\\')
        elif s == "true":
            return True
        elif s == "false":
            return False
        elif s == "null":
            return None
        elif s.isdigit() or (s.startswith('-') and s[1:].isdigit()):
            return int(s)
        else:
            return s

    # Helper to convert list of dicts to list of names
    def extract_names(items):
        if items == None:
            return []
        names = []
        for item in items:
            if item != None and type(item) == dict and "name" in item:
                names.append(item["name"])
        return names

    # Get all clientscopes
    all_clientscopes = get_json_list("client-scopes")

    # Filter by provided lists if given
    default_clientscopes_real = []
    optional_clientscopes_real = []

    if default_clientscopes != None:
        for name in default_clientscopes:
            found = False
            for cs in all_clientscopes:
                if cs != None and type(cs) == dict and cs.get("name") == name:
                    default_clientscopes_real.append(cs)
                    found = True
                    break
            if not found:
                fail("At least one of the default_clientscopes does not exist: " + name)

    if optional_clientscopes != None:
        for name in optional_clientscopes:
            found = False
            for cs in all_clientscopes:
                if cs != None and type(cs) == dict and cs.get("name") == name:
                    optional_clientscopes_real.append(cs)
                    found = True
                    break
            if not found:
                fail("At least one of the optional_clientscopes does not exist: " + name)

    # Get existing clientscope assignments
    path_prefix = "clients"
    if client_id == None:
        path_prefix = ""
    default_existing = get_json_list(path_prefix + "/default-default-client-scopes")
    optional_existing = get_json_list(path_prefix + "/default-optional-client-scopes")

    proposed = {
        "default_clientscopes": "no-change" if default_clientscopes == None else list(default_clientscopes),
        "optional_clientscopes": "no-change" if optional_clientscopes == None else list(optional_clientscopes)
    }

    existing = {
        "default_clientscopes": extract_names(default_existing),
        "optional_clientscopes": extract_names(optional_existing)
    }

    # Prepare new desired sets as name sets
    desired_default_names = set(default_clientscopes) if default_clientscopes != None else None
    desired_optional_names = set(optional_clientscopes) if optional_clientscopes != None else None

    current_default_names = set(extract_names(default_existing))
    current_optional_names = set(extract_names(optional_existing))

    # Compute changes
    to_add_default = []
    to_add_optional = []
    to_del_default = []
    to_del_optional = []

    if desired_default_names != None:
        for name in desired_default_names:
            if name not in current_default_names:
                for cs in all_clientscopes:
                    if cs != None and type(cs) == dict and cs.get("name") == name:
                        to_add_default.append(cs)
                        break
        for name in current_default_names:
            if name not in desired_default_names:
                for cs in default_existing:
                    if cs != None and type(cs) == dict and cs.get("name") == name:
                        to_del_default.append(cs)
                        break

    if desired_optional_names != None:
        for name in desired_optional_names:
            if name not in current_optional_names:
                for cs in all_clientscopes:
                    if cs != None and type(cs) == dict and cs.get("name") == name:
                        to_add_optional.append(cs)
                        break
        for name in current_optional_names:
            if name not in desired_optional_names:
                for cs in optional_existing:
                    if cs != None and type(cs) == dict and cs.get("name") == name:
                        to_del_optional.append(cs)
                        break

    changed = (
        len(to_add_default) > 0 or len(to_del_default) > 0 or
        len(to_add_optional) > 0 or len(to_del_optional) > 0
    )

    if changed:
        if ctx.check_mode:
            return {
                "changed": True,
                "msg": "would update clientscope types",
                "proposed": proposed,
                "existing": existing,
                "end_state": existing
            }

        # Delete first to allow type change
        for cs in to_del_default:
            cid = cs.get("id")
            if cid == None:
                fail("Missing id in clientscope to delete")
            request("DELETE", path_prefix + "/default-default-client-scopes/" + cid)
        for cs in to_del_optional:
            cid = cs.get("id")
            if cid == None:
                fail("Missing id in clientscope to delete")
            request("DELETE", path_prefix + "/default-optional-client-scopes/" + cid)

        # Add new assignments
        for cs in to_add_default:
            cid = cs.get("id")
            if cid == None:
                fail("Missing id in clientscope to add")
            request("POST", path_prefix + "/default-default-client-scopes/" + cid)
        for cs in to_add_optional:
            cid = cs.get("id")
            if cid == None:
                fail("Missing id in clientscope to add")
            request("POST", path_prefix + "/default-optional-client-scopes/" + cid)

    # Fetch end state
    end_default = get_json_list(path_prefix + "/default-default-client-scopes")
    end_optional = get_json_list(path_prefix + "/default-optional-client-scopes")

    end_state = {
        "default_clientscopes": extract_names(end_default),
        "optional_clientscopes": extract_names(end_optional)
    }

    return {
        "changed": changed,
        "msg": "Clientscope types updated" if changed else "No change required",
        "proposed": proposed,
        "existing": existing,
        "end_state": end_state
    }
