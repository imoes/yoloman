def main(ctx, params):
    # Required parameters
    api_token = params["api_token"]
    name = params["name"]
    project_id = params["project_id"]
    region = params["region"]
    state = params.get("state", "present")
    
    # Optional parameters
    api_timeout = params.get("api_timeout", 30)
    api_url = params.get("api_url", "https://api.scaleway.com")
    description = params.get("description", "")
    environment_variables = params.get("environment_variables", {})
    secret_environment_variables = params.get("secret_environment_variables", {})
    validate_certs = params.get("validate_certs", True)
    wait = params.get("wait", True)
    wait_sleep_time = params.get("wait_sleep_time", 3)
    wait_timeout = params.get("wait_timeout", 300)
    
    # Validate region
    valid_regions = ["fr-par", "nl-ams", "pl-waw"]
    if region not in valid_regions:
        fail("region must be one of " + ", ".join(valid_regions) + ", got: " + region)
    
    # Helper: build query string from dict
    def build_query(params_dict):
        if not params_dict:
            return ""
        parts = []
        for k, v in params_dict.items():
            parts.append(str(k) + "=" + str(v))
        return "?" + "&".join(parts)
    
    # Helper: simple JSON field extractor (string value)
    def extract_string_field(raw, field_name):
        pattern = '"' + field_name + '":'
        idx = raw.find(pattern)
        if idx == -1:
            return ""
        start = idx + len(pattern)
        while start < len(raw) and raw[start] in " \t\n\r\"":
            start += 1
        if start >= len(raw) or raw[start] != '"':
            return ""
        end = start + 1
        while end < len(raw) and raw[end] != '"':
            if raw[end] == '\\' and end + 1 < len(raw):
                end += 2
            else:
                end += 1
        return raw[start+1:end]
    
    # Helper: HTTP GET
    def http_get(path, query={}, ok_codes=[0, 200]):
        q = build_query(query)
        full_path = path + q
        res = ctx.run(
            ["curl", "-s", "-X", "GET", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", full_path],
            mutates=False
        )
        if res.rc != 0 and 0 not in ok_codes:
            fail("GET " + path + " failed: " + res.stderr)
        return res
    
    # Helper: HTTP POST
    def http_post(path, payload_str, ok_codes=[201]):
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", "-d", payload_str, path],
            mutates=True
        )
        if res.rc != 0 and 0 not in ok_codes:
            fail("POST " + path + " failed: " + res.stderr)
        return res
    
    # Helper: HTTP PATCH
    def http_patch(path, payload_str, ok_codes=[200]):
        res = ctx.run(
            ["curl", "-s", "-X", "PATCH", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", "-d", payload_str, path],
            mutates=True
        )
        if res.rc != 0 and 0 not in ok_codes:
            fail("PATCH " + path + " failed: " + res.stderr)
        return res
    
    # Helper: HTTP DELETE
    def http_delete(path, ok_codes=[204, 200]):
        res = ctx.run(
            ["curl", "-s", "-X", "DELETE", "-H", "Authorization: Bearer " + api_token, path],
            mutates=True
        )
        if res.rc != 0 and 0 not in ok_codes:
            fail("DELETE " + path + " failed: " + res.stderr)
        return res
    
    # API path for the resource
    api_path = api_url + "/functions/v1beta1/regions/%s/namespaces" % region
    
    # Helper: list namespaces
    def list_namespaces():
        res = http_get(api_path)
        if res.rc != 0:
            fail("Failed to list namespaces: " + res.stderr)
        raw = res.stdout
        if not raw.strip():
            return []
        if raw.startswith("[") and raw.endswith("]"):
            raw = raw[1:-1]
        # Split into individual object strings by tracking braces depth
        entries = []
        depth = 0
        cur = ""
        for ch in raw:
            if ch == '{':
                depth += 1
            if depth > 0:
                cur += ch
            if ch == '}':
                depth -= 1
                if depth == 0:
                    entries.append(cur)
                    cur = ""
        namespaces = []
        for entry in entries:
            ns = {}
            # Extract key fields
            for field in ["id", "name", "description", "project_id", "status"]:
                val = extract_string_field(entry, field)
                if val:
                    ns[field] = val
            # environment_variables and secret_environment_variables are dicts — parse as simple strings for now
            env_vars = extract_string_field(entry, "environment_variables")
            if env_vars:
                ns["environment_variables"] = env_vars
            secret_vars = extract_string_field(entry, "secret_environment_variables")
            if secret_vars:
                ns["secret_environment_variables"] = secret_vars
            if ns.get("name"):
                namespaces.append(ns)
        return namespaces
    
    # Helper: wait for status
    def wait_for_status(target_id, target_status, timeout=wait_timeout, interval=wait_sleep_time):
        elapsed = 0
        while elapsed < timeout:
            res = http_get(api_path + "/" + target_id)
            if res.rc == 0:
                raw = res.stdout
                status = extract_string_field(raw, "status")
                if status == target_status:
                    return True
            # Sleep interval — simulate by incrementing elapsed (no actual sleep in Starlark)
            elapsed += interval
        return False
    
    # Main logic
    namespaces = list_namespaces()
    ns_lookup = {}
    for ns in namespaces:
        ns_lookup[ns.get("name")] = ns
    
    if state == "absent":
        if name not in ns_lookup:
            return {"changed": False, "msg": "namespace not found, nothing to delete"}
        target = ns_lookup[name]
        target_id = target.get("id", "")
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete namespace " + name}
        res = http_delete(api_path + "/" + target_id)
        if res.rc != 0:
            fail("Failed to delete namespace: " + res.stderr)
        return {"changed": True, "msg": "namespace deleted"}
    
    # state == "present"
    if ctx.check_mode and name not in ns_lookup:
        return {"changed": True, "msg": "would create namespace " + name}
    
    # Prepare payload strings manually to avoid external deps
    def escape_json_string(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')
    
    def build_json_dict(d):
        parts = []
        for k, v in d.items():
            # Only handle simple string values for JSON dict encoding
            if type(v) == "string":
                parts.append('"' + escape_json_string(k) + '": "' + escape_json_string(str(v)) + '"')
            elif type(v) == "bool":
                parts.append('"' + escape_json_string(k) + '": ' + ("true" if v else "false"))
            elif type(v) == "int":
                parts.append('"' + escape_json_string(k) + '": ' + str(v))
        return "{" + ", ".join(parts) + "}"
    
    # Build JSON payload for create/update
    env_json = build_json_dict(environment_variables)
    secret_env_json = build_json_dict(secret_environment_variables)
    
    if name not in ns_lookup:
        # Create
        payload_str = '{"name": "' + escape_json_string(name) + '", "project_id": "' + escape_json_string(project_id) + '", "description": "' + escape_json_string(description) + '", "environment_variables": ' + env_json + ', "secret_environment_variables": ' + secret_env_json + '}'
        if ctx.check_mode:
            return {"changed": True, "msg": "would create namespace " + name}
        res = http_post(api_path, payload_str)
        if res.rc != 201:
            fail("Failed to create namespace: " + res.stderr)
        created_id = extract_string_field(res.stdout, "id")
        if not created_id:
            fail("Failed to parse namespace ID from creation response")
        if wait:
            ok = wait_for_status(created_id, "ready")
            if not ok:
                fail("Timed out waiting for namespace to become ready")
        return {"changed": True, "msg": "namespace created"}
    
    # namespace exists — check for updates
    target = ns_lookup[name]
    target_id = target.get("id", "")
    
    # Compare only mutable, non-secret fields
    needs_update = False
    if description != target.get("description", ""):
        needs_update = True
    # Environment variables comparison (simple string comparison)
    env_target_str = target.get("environment_variables", "{}")
    if env_json != env_target_str:
        needs_update = True
    
    if not needs_update:
        return {"changed": False, "msg": "namespace already in desired state"}
    
    if ctx.check_mode:
        return {"changed": True, "msg": "would update namespace " + name}
    
    # Prepare patch payload
    patch_payload = '{"description": "' + escape_json_string(description) + '", "environment_variables": ' + env_json + '}'
    res = http_patch(api_path + "/" + target_id, patch_payload)
    if res.rc != 200:
        fail("Failed to update namespace: " + res.stderr)
    
    if wait:
        ok = wait_for_status(target_id, "ready")
        if not ok:
            fail("Timed out waiting for namespace to become ready after update")
    
    return {"changed": True, "msg": "namespace updated"}
