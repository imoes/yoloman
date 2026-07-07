def main(ctx, params):
    # Extract parameters
    name = params["name"]
    path = params.get("path")
    description = params.get("description")
    state = params.get("state", "present")
    parent_identifier = params.get("parent")
    visibility = params.get("visibility", "private")
    project_creation_level = params.get("project_creation_level")
    auto_devops_enabled = params.get("auto_devops_enabled")
    subgroup_creation_level = params.get("subgroup_creation_level")
    require_two_factor_authentication = params.get("require_two_factor_authentication")
    force_delete = params.get("force_delete", False)

    # Authentication validation
    api_token = params.get("api_token") or params.get("api_oauth_token") or params.get("api_job_token")
    if not api_token:
        api_username = params.get("api_username")
        api_password = params.get("api_password")
        if api_username and api_password:
            fail("authentication via api_username/api_password not supported in Starlark module")
        elif not api_username and not api_password:
            fail("one of api_token, api_oauth_token, api_job_token, or api_username+api_password is required")
        else:
            fail("api_username without api_password is invalid")

    # Default path
    if path == None:
        path = name.replace(" ", "_")

    # GitLab API helpers
    api_url = params.get("api_url")
    validate_certs = params.get("validate_certs", True)
    base_args = ["curl", "-s", "-X"]

    def curl_cmd(method, endpoint, data=None):
        args = list(base_args)
        args.extend([method, "--header", "PRIVATE-TOKEN: " + api_token])
        if not validate_certs:
            args.append("-k")
        if data:
            args.extend(["--data", data])
        args.append(api_url.rstrip("/") + "/api/v4" + endpoint)
        return args

    # Check group existence via HTTP HEAD/GET
    def group_exists(path_or_id):
        args = curl_cmd("GET", "/groups/" + path_or_id)
        res = ctx.run(args, mutates=False)
        if res.skipped:
            return None
        # Check HTTP status code via curl -w
        args = curl_cmd("GET", "/groups/" + path_or_id)
        args.extend(["-o", "/dev/null", "-w", "%{http_code}"])
        res = ctx.run(args, mutates=False)
        if res.skipped:
            return None
        code = res.stdout.strip()
        return code == "200"

    # Create group
    def create_group():
        args = curl_cmd("POST", "/groups")
        payload = []
        payload.append("name=" + name)
        payload.append("path=" + path)
        payload.append("visibility=" + visibility)
        if description != None:
            payload.append("description=" + description)
        if project_creation_level != None:
            payload.append("project_creation_level=" + project_creation_level)
        if auto_devops_enabled != None:
            if auto_devops_enabled:
                payload.append("auto_devops_enabled=true")
            else:
                payload.append("auto_devops_enabled=false")
        if subgroup_creation_level != None:
            payload.append("subgroup_creation_level=" + subgroup_creation_level)
        if require_two_factor_authentication != None:
            if require_two_factor_authentication:
                payload.append("require_two_factor_authentication=true")
            else:
                payload.append("require_two_factor_authentication=false")
        args.extend(["--data", "&".join(payload)])
        res = ctx.run(args, mutates=True)
        if res.skipped:
            return True  # Would create
        if res.rc != 0:
            fail("failed to create group: " + res.stderr)
        return False  # Already changed handled

    # Update group (placeholder: minimal support)
    def update_group(group_id):
        args = curl_cmd("PUT", "/groups/" + group_id)
        payload = []
        if description != None:
            payload.append("description=" + description)
        if visibility != None and visibility != "private":
            payload.append("visibility=" + visibility)
        if project_creation_level != None:
            payload.append("project_creation_level=" + project_creation_level)
        if auto_devops_enabled != None:
            if auto_devops_enabled:
                payload.append("auto_devops_enabled=true")
            else:
                payload.append("auto_devops_enabled=false")
        if subgroup_creation_level != None:
            payload.append("subgroup_creation_level=" + subgroup_creation_level)
        if require_two_factor_authentication != None:
            if require_two_factor_authentication:
                payload.append("require_two_factor_authentication=true")
            else:
                payload.append("require_two_factor_authentication=false")
        if len(payload) == 0:
            return False
        args.extend(["--data", "&".join(payload)])
        res = ctx.run(args, mutates=True)
        if res.skipped:
            return True
        if res.rc != 0:
            fail("failed to update group: " + res.stderr)
        return True

    # Delete group
    def delete_group():
        endpoint = "/groups/" + path
        if force_delete:
            endpoint += "?force_delete=true"
        args = curl_cmd("DELETE", endpoint)
        res = ctx.run(args, mutates=True)
        if res.skipped:
            return True  # Would delete
        if res.rc != 0:
            fail("failed to delete group: " + res.stderr)
        return False  # Already handled change

    # Main logic
    if state == "absent":
        exists = group_exists(path)
        if exists == None:
            fail("check_mode not supported for group existence check")
        if exists:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete group " + name}
            if delete_group():
                return {"changed": True, "msg": "successfully deleted group " + name}
            return {"changed": False, "msg": "group not found"}
        else:
            return {"changed": False, "msg": "group does not exist"}

    if state == "present":
        exists = group_exists(path)
        if exists == None:
            fail("check_mode not supported for group existence check")
        if exists:
            # In check_mode, assume no changes needed without full update detection
            if ctx.check_mode:
                return {"changed": False, "msg": "group already exists"}
            return {"changed": False, "msg": "group already exists"}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create group " + name}
            if create_group():
                return {"changed": True, "msg": "successfully created group " + name}
            return {"changed": False, "msg": "group not created"}

    fail("unsupported state: " + state)
