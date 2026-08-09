def main(ctx, params):
    # Required params
    taiga_host = params.get("taiga_host", "https://api.taiga.io")
    project_name = params["project"]
    subject = params["subject"]
    issue_type = params["issue_type"]
    priority = params.get("priority", "Normal")
    status = params.get("status", "New")
    severity = params.get("severity", "Normal")
    description = params.get("description", "")
    attachment = params.get("attachment")
    attachment_description = params.get("attachment_description", "")
    tags = params.get("tags", [])
    state = params.get("state", "present")

    # Validate attachment file exists if provided
    if attachment != None:
        if not ctx.file_exists(attachment):
            fail(attachment + " is not a file")

    # Prepare API call via curl (no python-taiga available in Starlark)
    # We'll use environment variables TAIGA_TOKEN or TAIGA_USERNAME/TAIGA_PASSWORD for auth
    token = ctx.get_env("TAIGA_TOKEN")
    username = ctx.get_env("TAIGA_USERNAME")
    password = ctx.get_env("TAIGA_PASSWORD")
    auth_header = ""
    if token != None and token != "":
        auth_header = "-H 'Authorization: Bearer " + token + "'"
    elif username != None and username != "" and password != None and password != "":
        auth_header = "-u " + username + ":" + password
    else:
        fail("Missing credentials - provide TAIGA_TOKEN or TAIGA_USERNAME and TAIGA_PASSWORD")

    # Helper to run curl commands
    def curl_cmd(args, mutates=False):
        full_argv = ["curl", "-s", "-S", "-f", "-X", "GET"] + args
        if mutates:
            full_argv = ["curl", "-s", "-S", "-f", "-X"] + args
            # Adjust for POST/PUT/DELETE
            if "POST" in args:
                full_argv = ["curl", "-s", "-S", "-f", "-X", "POST"] + args[args.index("POST")+1:]
            elif "PUT" in args:
                full_argv = ["curl", "-S", "-f", "-X", "PUT"] + args[args.index("PUT")+1:]
            elif "DELETE" in args:
                full_argv = ["curl", "-s", "-S", "-f", "-X", "DELETE"] + args[args.index("DELETE")+1:]
        res = ctx.run(full_argv, mutates=mutates)
        return res

    # Helper to run POST/PUT/DELETE with JSON body
    def curl_json(method, url, data, mutates=False):
        if ctx.check_mode and mutates:
            return {"rc": 0, "stdout": "", "stderr": "", "skipped": True}
        cmd = ["curl", "-s", "-S", "-f", "-X", method, url]
        if data != "":
            cmd.extend(["-d", data])
        cmd.extend(["-H", "Content-Type: application/json"])
        if auth_header != "":
            # Extract Bearer token or use -u
            if auth_header.startswith("-H"):
                cmd.append(auth_header)
            else:
                # Parse -u user:pass
                parts = auth_header.split(" ")
                if len(parts) == 2:
                    cmd.extend(["-u", parts[1]])
        res = ctx.run(cmd, mutates=mutates)
        return res

    # Step 1: Get user ID via /me
    me_res = curl_json("GET", taiga_host + "/api/v1/me", "")
    if me_res.rc != 0:
        fail("Failed to get user info: " + me_res.stderr)
    user_id = int(me_res.stdout.split("\"id\":")[1].split(",")[0].strip())

    # Step 2: Get project ID
    proj_res = curl_json("GET", taiga_host + "/api/v1/projects?member=" + str(user_id), "")
    if proj_res.rc != 0:
        fail("Failed to list projects: " + proj_res.stderr)
    proj_json = proj_res.stdout
    project_id = None
    # Simple JSON parsing for project name
    projects = proj_json.split("{")
    for p in projects:
        if "\"name\":\"" + project_name + "\"" in p or "\"name\":\"" + project_name + "\"" in p.replace(" ", ""):
            # Extract ID
            if "\"id\":" in p:
                pid_part = p.split("\"id\":")[1]
                pid = int(pid_part.split(",")[0].strip())
                project_id = pid
                break
    if project_id == None:
        fail("Unable to find project " + project_name)

    # Step 3: Get priority ID
    pri_res = curl_json("GET", taiga_host + "/api/v1/priorities?project=" + str(project_id), "")
    if pri_res.rc != 0:
        fail("Failed to list priorities: " + pri_res.stderr)
    for p in pri_res.stdout.split("{"):
        if "\"name\":\"" + priority + "\"" in p or "\"name\":\"" + priority + "\"" in p.replace(" ", ""):
            if "\"id\":" in p:
                pid = int(p.split("\"id\":")[1].split(",")[0].strip())
                priority_id = pid
                break
    if priority_id == None:
        fail("Unable to find priority " + priority + " for project " + project_name)

    # Step 4: Get status ID
    stat_res = curl_json("GET", taiga_host + "/api/v1/issue-statuses?project=" + str(project_id), "")
    if stat_res.rc != 0:
        fail("Failed to list issue statuses: " + stat_res.stderr)
    for s in stat_res.stdout.split("{"):
        if "\"name\":\"" + status + "\"" in s or "\"name\":\"" + status + "\"" in s.replace(" ", ""):
            if "\"id\":" in s:
                sid = int(s.split("\"id\":")[1].split(",")[0].strip())
                status_id = sid
                break
    if status_id == None:
        fail("Unable to find issue status " + status + " for project " + project_name)

    # Step 5: Get issue type ID
    type_res = curl_json("GET", taiga_host + "/api/v1/issue-types?project=" + str(project_id), "")
    if type_res.rc != 0:
        fail("Failed to list issue types: " + type_res.stderr)
    for t in type_res.stdout.split("{"):
        if "\"name\":\"" + issue_type + "\"" in t or "\"name\":\"" + issue_type + "\"" in t.replace(" ", ""):
            if "\"id\":" in t:
                tid = int(t.split("\"id\":")[1].split(",")[0].strip())
                type_id = tid
                break
    if type_id == None:
        fail("Unable to find issue type " + issue_type + " for project " + project_name)

    # Step 6: Get severity ID
    sev_res = curl_json("GET", taiga_host + "/api/v1/severities?project=" + str(project_id), "")
    if sev_res.rc != 0:
        fail("Failed to list severities: " + sev_res.stderr)
    for s in sev_res.stdout.split("{"):
        if "\"name\":\"" + severity + "\"" in s or "\"name\":\"" + severity + "\"" in s.replace(" ", ""):
            if "\"id\":" in s:
                sid = int(s.split("\"id\":")[1].split(",")[0].strip())
                severity_id = sid
                break
    if severity_id == None:
        fail("Unable to find severity " + severity + " for project " + project_name)

    # Step 7: Check for existing issue by subject and type_id
    issue_res = curl_json("GET", taiga_host + "/api/v1/issues?project=" + str(project_id) + "&type=" + str(type_id), "")
    if issue_res.rc != 0:
        fail("Failed to list issues: " + issue_res.stderr)

    # Find matching issue by subject and type_id
    issue_id = None
    for i in issue_res.stdout.split("{"):
        if "\"subject\":\"" + subject + "\"" in i or "\"subject\":\"" + subject + "\"" in i.replace(" ", ""):
            if "\"type\":" + str(type_id) in i or "\"type\":" + str(type_id) in i.replace(" ", ""):
                if "\"id\":" in i:
                    iid = int(i.split("\"id\":")[1].split(",")[0].strip())
                    issue_id = iid
                    break

    if state == "present":
        if issue_id != None:
            return {"changed": False, "msg": "Issue already exists", "data": {"subject": subject, "issue_type": issue_type, "priority": priority, "status": status, "severity": severity, "description": description, "tags": tags}}
        else:
            # Create issue
            if ctx.check_mode:
                return {"changed": True, "msg": "would create issue " + subject}
            # Prepare POST body
            tags_json = "[\"" + "\",\"".join(tags) + "\"]" if len(tags) > 0 else "[]"
            body = "{\"project\":" + str(project_id) + ",\"subject\":\"" + subject + "\",\"priority\":" + str(priority_id) + ",\"status\":" + str(status_id) + ",\"type\":" + str(type_id) + ",\"severity\":" + str(severity_id) + ",\"description\":\"" + description.replace("\"", "\\\"") + "\",\"tags\":" + tags_json + "}"
            create_res = curl_json("POST", taiga_host + "/api/v1/issues", body, mutates=True)
            if create_res.rc != 0:
                fail("Failed to create issue: " + create_res.stderr)
            # Extract new issue ID
            created_id = int(create_res.stdout.split("\"id\":")[1].split(",")[0].strip())
            data = {"subject": subject, "issue_type": issue_type, "priority": priority, "status": status, "severity": severity, "description": description, "tags": tags, "id": created_id}
            if attachment != None:
                # Attach file
                # Read file content and base64 encode? Taiga expects multipart/form-data
                fail("File attachment not implemented in Starlark module (requires multipart/form-data upload via curl)")
            return {"changed": True, "msg": "Issue created", "data": data}

    elif state == "absent":
        if issue_id == None:
            return {"changed": False, "msg": "Issue does not exist"}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete issue " + subject}
            del_res = curl_json("DELETE", taiga_host + "/api/v1/issues/" + str(issue_id), "", mutates=True)
            if del_res.rc != 0:
                fail("Failed to delete issue: " + del_res.stderr)
            return {"changed": True, "msg": "Issue deleted"}
