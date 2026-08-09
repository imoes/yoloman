def main(ctx, params):
    api_url = params.get("api_url")
    api_token = params.get("api_token")
    api_oauth_token = params.get("api_oauth_token")
    api_job_token = params.get("api_job_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    project = params["project"]
    branch = params["branch"]
    ref_branch = params.get("ref_branch")
    state = params.get("state", "present")
    ca_path = params.get("ca_path")
    validate_certs = params.get("validate_certs", True)

    # Auth validation — mutually exclusive and required_one_of
    auth_methods = [
        bool(api_username),
        bool(api_token),
        bool(api_oauth_token),
        bool(api_job_token),
    ]
    if len(auth_methods) != 1:
        fail("exactly one of api_username, api_token, api_oauth_token, or api_job_token must be provided")
    if api_username != None and api_password == None:
        fail("api_password is required when using api_username")

    # CA cert handling
    ca_option = []
    if ca_path != None:
        ca_option = ["--cacert", ca_path]
    if not validate_certs:
        ca_option = ["--insecure"]

    # Determine project ID (namespace/project or numeric)
    proj_res = ctx.run(
        ["curl", "-sS", "-w", "\n%{http_code}"] + ca_option + ["-H", "Content-Type: application/json"] +
        (["-H", "Private-Token: " + api_token] if api_token != None else []) +
        (["-H", "Authorization: Bearer " + api_oauth_token] if api_oauth_token != None else []) +
        (["-H", "JOB-TOKEN: " + api_job_token] if api_job_token != None else []) +
        (["-u", api_username + ":" + api_password] if api_username != None and api_password != None else []) +
        ["--get", api_url.rstrip("/") + "/projects", "--data-urlencode", "search=" + project],
        mutates=False
    )
    if proj_res.rc != 0:
        fail("failed to query projects: " + proj_res.stderr)
    lines = proj_res.stdout.strip().split("\n")
    if len(lines) < 2:
        fail("unexpected response from projects list")
    http_code = lines[-1]
    proj_json = "\n".join(lines[:-1])
    if http_code not in ["200", "201"]:
        fail("project search failed with HTTP " + http_code + ": " + proj_json)

    # Parse response to find matching project ID
    project_id = None
    raw = proj_json.replace("\n", " ").replace("\r", " ")
    obj_start = 0
    depth = 0
    for i in range(len(raw)):
        ch = raw[i]
        if ch == '{':
            if depth == 0:
                obj_start = i
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                obj_str = raw[obj_start:i+1]
                # extract id
                j = obj_str.find('"id"')
                if j == -1:
                    j = obj_str.find("'id'")
                if j != -1:
                    j += len('"id"')
                    while j < len(obj_str) and obj_str[j] not in "0123456789-":
                        j += 1
                    if j < len(obj_str) and obj_str[j] in "0123456789-":
                        end = j
                        while end < len(obj_str) and obj_str[end] in "0123456789-":
                            end += 1
                        pid = obj_str[j:end]
                        if pid != "":
                            # also get path for match
                            k = obj_str.find('"path"')
                            if k == -1:
                                k = obj_str.find("'path'")
                            proj_path = ""
                            if k != -1:
                                k += len('"path"')
                                while k < len(obj_str) and obj_str[k] not in '"\'':
                                    k += 1
                                if k < len(obj_str):
                                    endq = k + 1
                                    while endq < len(obj_str) and obj_str[endq] not in '"\'':
                                        endq += 1
                                    proj_path = obj_str[k+1:endq]
                                if proj_path == project or (obj_str.find('"path_with_namespace"') != -1 and project in obj_str):
                                    project_id = int(pid)
                                    break

    if project_id == None:
        fail("project not found: " + project)

    # Check branch existence
    branch_check = ctx.run(
        ["curl", "-sS", "-w", "\n%{http_code}"] + ca_option + ["-H", "Content-Type: application/json"] +
        (["-H", "Private-Token: " + api_token] if api_token != None else []) +
        (["-H", "Authorization: Bearer " + api_oauth_token] if api_oauth_token != None else []) +
        (["-H", "JOB-TOKEN: " + api_job_token] if api_job_token != None else []) +
        (["-u", api_username + ":" + api_password] if api_username != None and api_password != None else []) +
        ["--get", api_url.rstrip("/") + "/projects/" + str(project_id) + "/repository/branches", "--data-urlencode", "search=" + branch],
        mutates=False
    )
    if branch_check.rc != 0:
        fail("failed to query branches: " + branch_check.stderr)
    lines = branch_check.stdout.strip().split("\n")
    if len(lines) < 2:
        fail("unexpected branch response")
    http_code = lines[-1]
    branch_json = "\n".join(lines[:-1])
    if http_code not in ["200", "201"]:
        fail("branch search failed with HTTP " + http_code + ": " + branch_json)

    branch_exists = False
    raw = branch_json.replace("\n", " ").replace("\r", " ")
    obj_start = 0
    depth = 0
    for i in range(len(raw)):
        ch = raw[i]
        if ch == '{':
            if depth == 0:
                obj_start = i
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                obj_str = raw[obj_start:i+1]
                if '"name"' in obj_str or "'name'" in obj_str:
                    # extract name
                    k = obj_str.find('"name"')
                    if k == -1:
                        k = obj_str.find("'name'")
                    if k != -1:
                        k += len('"name"')
                        while k < len(obj_str) and obj_str[k] not in '"\'':
                            k += 1
                        if k < len(obj_str):
                            endq = k + 1
                            while endq < len(obj_str) and obj_str[endq] not in '"\'':
                                endq += 1
                            name = obj_str[k+1:endq]
                            if name == branch:
                                branch_exists = True
                                break

    # State logic
    if state == "present":
        if branch_exists:
            return {"changed": False, "msg": "Branch " + branch + " already exists"}
        if ref_branch == None:
            fail("ref_branch is required when state=present")
        # Verify ref_branch exists
        ref_check = ctx.run(
            ["curl", "-sS", "-w", "\n%{http_code}"] + ca_option + ["-H", "Content-Type: application/json"] +
            (["-H", "Private-Token: " + api_token] if api_token != None else []) +
            (["-H", "Authorization: Bearer " + api_oauth_token] if api_oauth_token != None else []) +
            (["-H", "JOB-TOKEN: " + api_job_token] if api_job_token != None else []) +
            (["-u", api_username + ":" + api_password] if api_username != None and api_password != None else []) +
            ["--get", api_url.rstrip("/") + "/projects/" + str(project_id) + "/repository/branches", "--data-urlencode", "search=" + ref_branch],
            mutates=False
        )
        if ref_check.rc != 0:
            fail("failed to query ref_branch: " + ref_check.stderr)
        ref_lines = ref_check.stdout.strip().split("\n")
        if len(ref_lines) < 2:
            fail("unexpected ref_branch response")
        ref_http = ref_lines[-1]
        ref_json = "\n".join(ref_lines[:-1])
        if ref_http not in ["200", "201"]:
            fail("ref_branch query failed with HTTP " + ref_http + ": " + ref_json)

        ref_exists = False
        raw = ref_json.replace("\n", " ").replace("\r", " ")
        obj_start = 0
        depth = 0
        for i in range(len(raw)):
            ch = raw[i]
            if ch == '{':
                if depth == 0:
                    obj_start = i
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    obj_str = raw[obj_start:i+1]
                    if '"name"' in obj_str or "'name'" in obj_str:
                        k = obj_str.find('"name"')
                        if k == -1:
                            k = obj_str.find("'name'")
                        if k != -1:
                            k += len('"name"')
                            while k < len(obj_str) and obj_str[k] not in '"\'':
                                k += 1
                            if k < len(obj_str):
                                endq = k + 1
                                while endq < len(obj_str) and obj_str[endq] not in '"\'':
                                    endq += 1
                                name = obj_str[k+1:endq]
                                if name == ref_branch:
                                    ref_exists = True
                                    break

        if not ref_exists:
            fail("Reference branch " + ref_branch + " does not exist")

        # Create branch
        create_res = ctx.run(
            ["curl", "-sS", "-w", "\n%{http_code}"] + ca_option + ["-H", "Content-Type: application/json"] +
            (["-H", "Private-Token: " + api_token] if api_token != None else []) +
            (["-H", "Authorization: Bearer " + api_oauth_token] if api_oauth_token != None else []) +
            (["-H", "JOB-TOKEN: " + api_job_token] if api_job_token != None else []) +
            (["-u", api_username + ":" + api_password] if api_username != None and api_password != None else []) +
            ["-X", "POST", api_url.rstrip("/") + "/projects/" + str(project_id) + "/repository/branches", "-d",
             '{"branch": "' + branch + '", "ref": "' + ref_branch + '"}'],
            mutates=True
        )
        if create_res.rc != 0:
            fail("failed to create branch " + branch + ": " + create_res.stderr)
        create_http = create_res.stdout.strip().split("\n")[-1]
        if create_http not in ["200", "201"]:
            fail("branch creation failed with HTTP " + create_http)
        return {"changed": True, "msg": "Branch " + branch + " created"}

    elif state == "absent":
        if not branch_exists:
            return {"changed": False, "msg": "Branch " + branch + " does not exist"}
        # Delete branch
        delete_res = ctx.run(
            ["curl", "-sS", "-w", "\n%{http_code}"] + ca_option + ["-H", "Content-Type: application/json"] +
            (["-H", "Private-Token: " + api_token] if api_token != None else []) +
            (["-H", "Authorization: Bearer " + api_oauth_token] if api_oauth_token != None else []) +
            (["-H", "JOB-TOKEN: " + api_job_token] if api_job_token != None else []) +
            (["-u", api_username + ":" + api_password] if api_username != None and api_password != None else []) +
            ["-X", "DELETE", api_url.rstrip("/") + "/projects/" + str(project_id) + "/repository/branches/" + branch],
            mutates=True
        )
        if delete_res.rc != 0:
            fail("failed to delete branch " + branch + ": " + delete_res.stderr)
        delete_http = delete_res.stdout.strip().split("\n")[-1]
        if delete_http not in ["200", "204"]:
            fail("branch deletion failed with HTTP " + delete_http)
        return {"changed": True, "msg": "Branch " + branch + " deleted"}

    else:
        fail("unsupported state: " + state)
