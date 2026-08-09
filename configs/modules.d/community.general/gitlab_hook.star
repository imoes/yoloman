def main(ctx, params):
    # Extract parameters
    project = params["project"]
    hook_url = params["hook_url"]
    state = params.get("state", "present")
    push_events = params.get("push_events", True)
    push_events_branch_filter = params.get("push_events_branch_filter", "")
    issues_events = params.get("issues_events", False)
    merge_requests_events = params.get("merge_requests_events", False)
    tag_push_events = params.get("tag_push_events", False)
    note_events = params.get("note_events", False)
    job_events = params.get("job_events", False)
    pipeline_events = params.get("pipeline_events", False)
    wiki_page_events = params.get("wiki_page_events", False)
    hook_validate_certs = params.get("hook_validate_certs", False)
    token = params.get("token")

    # Authentication: use first available method in priority order
    api_token = params.get("api_token")
    api_oauth_token = params.get("api_oauth_token")
    api_job_token = params.get("api_job_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    api_url = params.get("api_url")

    # Build curl command for authentication headers
    auth_headers = []
    if api_token:
        auth_headers.append("-H")
        auth_headers.append("PRIVATE-TOKEN:" + api_token)
    elif api_oauth_token:
        auth_headers.append("-H")
        auth_headers.append("Authorization:Bearer " + api_oauth_token)
    elif api_job_token:
        auth_headers.append("-H")
        auth_headers.append("JOB-TOKEN:" + api_job_token)
    elif api_username and api_password:
        auth_headers.append("-u")
        auth_headers.append(api_username + ":" + api_password)
    else:
        fail("Authentication credentials required: api_token, api_oauth_token, api_job_token, or api_username+api_password")

    # Build base API URL
    base_url = api_url.rstrip("/") + "/api/v4"

    # Determine if SSL verification is enabled
    validate_certs = params.get("validate_certs", True)
    ssl_flag = [] if validate_certs else ["-k"]

    # Step 1: Find project ID
    project_url = base_url + "/projects/" + project
    res = ctx.run(["curl", "-sS"] + ssl_flag + auth_headers + ["-X", "GET", project_url], mutates=False)
    if res.rc != 0:
        fail("Failed to retrieve project " + project + ": " + res.stderr)
    project_data = res.stdout.strip()
    if not project_data or '"id"' not in project_data:
        fail("Project " + project + " not found")

    # Parse project ID (simple extraction)
    pid = None
    for line in project_data.split("\n"):
        if '"id"' in line and ':' in line:
            parts = line.split('"id"')
            if len(parts) >= 2:
                val = parts[1].strip().lstrip(":").lstrip(" ").lstrip('"')
                if val.isdigit():
                    pid = val
                    break
    if pid == None:
        fail("Failed to parse project ID from response")

    # Step 2: Get list of hooks to find existing hook by URL
    hooks_url = base_url + "/projects/" + pid + "/hooks"
    res = ctx.run(["curl", "-sS"] + ssl_flag + auth_headers + ["-X", "GET", hooks_url], mutates=False)
    if res.rc != 0:
        fail("Failed to list hooks: " + res.stderr)

    # Find matching hook
    existing_hook_id = None
    existing_hook_data = res.stdout.strip()
    if existing_hook_data:
        lines = existing_hook_data.split("\n")
        current_obj = {}
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("{"):
                current_obj = {}
            elif stripped == "}":
                if current_obj.get("url") == hook_url:
                    if "id" in current_obj:
                        existing_hook_id = str(current_obj["id"])
                        break
                current_obj = {}
            elif ":" in stripped:
                key, value = stripped.split(":", 1)
                key = key.strip().strip('"')
                value = value.strip().strip('"')
                if key == "id" and value.isdigit():
                    current_obj["id"] = int(value)
                elif key == "url":
                    current_obj["url"] = value

    if state == "absent":
        if existing_hook_id == None:
            return {"changed": False, "msg": "Hook not found and thus not deleted"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete hook " + hook_url}
        delete_url = hooks_url + "/" + existing_hook_id
        res = ctx.run(["curl", "-sS"] + ssl_flag + auth_headers + ["-X", "DELETE", delete_url], mutates=True)
        if res.rc != 0:
            fail("Failed to delete hook: " + res.stderr)
        return {"changed": True, "msg": "Hook successfully deleted"}

    # State == 'present'
    if ctx.check_mode:
        # Determine if update would be needed
        would_change = True
        if existing_hook_id != None:
            # Compare all fields — but note: token cannot be retrieved, so if provided, it's always a change
            would_change = token != None
        return {"changed": would_change, "msg": "would create/update hook " + hook_url}

    # Build POST data payload
    payload = {
        "url": hook_url,
        "push_events": "true" if push_events else "false",
        "push_events_branch_filter": push_events_branch_filter,
        "issues_events": "true" if issues_events else "false",
        "merge_requests_events": "true" if merge_requests_events else "false",
        "tag_push_events": "true" if tag_push_events else "false",
        "note_events": "true" if note_events else "false",
        "job_events": "true" if job_events else "false",
        "pipeline_events": "true" if pipeline_events else "false",
        "wiki_page_events": "true" if wiki_page_events else "false",
        "enable_ssl_verification": "true" if hook_validate_certs else "false",
    }
    if token != None:
        payload["token"] = token

    # Build JSON payload string manually (avoiding json module)
    def to_json_str(d):
        items = []
        for k, v in d.items():
            items.append('"' + k + '":"' + v + '"')
        return "{" + ",".join(items) + "}"

    json_data = to_json_str(payload)

    if existing_hook_id == None:
        # Create new hook
        res = ctx.run(["curl", "-sS"] + ssl_flag + auth_headers + ["-X", "POST", "-H", "Content-Type:application/json", "-d", json_data, hooks_url], mutates=True)
        if res.rc != 0:
            fail("Failed to create hook: " + res.stderr)
        return {"changed": True, "msg": "Hook successfully created"}
    else:
        # Update existing hook
        update_url = hooks_url + "/" + existing_hook_id
        res = ctx.run(["curl", "-sS"] + ssl_flag + auth_headers + ["-X", "PUT", "-H", "Content-Type:application/json", "-d", json_data, update_url], mutates=True)
        if res.rc != 0:
            fail("Failed to update hook: " + res.stderr)
        return {"changed": True, "msg": "Hook successfully updated"}
