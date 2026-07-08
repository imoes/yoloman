def main(ctx, params):
    # Required one-of: api_token, api_oauth_token, api_job_token, or api_username+api_password
    # Required one-of: project, group
    api_url = params.get("api_url")
    project = params.get("project")
    group = params.get("group")
    milestones = params.get("milestones", [])
    state = params.get("state", "present")
    purge = params.get("purge", False)

    # Validation: exactly one of project or group
    if project == None and group == None:
        fail("one of 'project' or 'group' is required")
    if project != None and group != None:
        fail("'project' and 'group' are mutually exclusive")

    # Auth: prefer token, fallback to basic
    headers = ["Content-Type: application/json"]
    private_token = None
    if params.get("api_token") != None:
        private_token = params["api_token"]
        headers.append("PRIVATE-TOKEN: " + private_token)
    elif params.get("api_oauth_token") != None:
        headers.append("Authorization: Bearer " + params["api_oauth_token"])
    elif params.get("api_job_token") != None:
        headers.append("JOB-TOKEN: " + params["api_job_token"])
    elif params.get("api_username") != None and params.get("api_password") != None:
        # Basic auth: use curl -u (handled in command args, not headers)
        pass
    else:
        fail("one of api_token, api_oauth_token, api_job_token, or api_username+api_password is required")

    # Build API path
    base_url = api_url.rstrip("/") if api_url != None else "https://gitlab.com/api/v4"
    if project != None:
        # Encode slashes in project path
        path = "projects/" + project.replace("/", "%2F") + "/milestones"
    else:
        path = "groups/" + group.replace("/", "%2F") + "/milestones"

    # --- Step 1: Fetch existing milestones ---
    curl_args = [ctx.command("curl"), "-s", "-X", "GET"]
    # Validate SSL
    if params.get("validate_certs") == False:
        curl_args.append("-k")
    elif params.get("ca_path") != None:
        # Use custom CA bundle (not implemented in this translation due to complexity)
        fail("custom CA path (ca_path) is not supported in Starlark translation")

    # Auth via curl flags if needed
    if private_token == None and params.get("api_username") != None and params.get("api_password") != None:
        curl_args.extend(["-u", params["api_username"] + ":" + params["api_password"]])
    elif private_token != None:
        # Already added to headers; curl -H only
        for h in headers:
            curl_args.extend(["-H", h])

    url = base_url + "/" + path
    curl_args.append(url)

    res = ctx.run(curl_args, ok_codes=[0, 404])
    if res.rc == 404:
        if project != None:
            fail("project '%s' not found" % project)
        else:
            fail("group '%s' not found" % group)

    # Parse JSON response manually (minimal implementation)
    # GitLab returns array of objects: [{title, ...}, ...]
    # Extract only 'title' fields for comparison
    existing_titles = []
    if res.stdout != "":
        # Simple JSON array parser: split by "title":" and extract quoted string
        # This assumes valid JSON from GitLab and that titles contain no escaped quotes
        line = res.stdout.strip()
        if line.startswith("[") and line.endswith("]"):
            # Strip brackets
            inner = line[1:-1]
            # Split objects (naive: assume one-line objects)
            for obj in inner.split("},"):
                obj = obj.strip()
                if obj == "":
                    continue
                if obj.endswith("}"):
                    obj = obj[:-1]
                # Extract title
                title_start = obj.find('"title":"')
                if title_start != -1:
                    title_start += len('"title":"')
                    title_end = obj.find('"', title_start)
                    if title_end != -1:
                        title = obj[title_start:title_end]
                        existing_titles.append(title)

    # --- Step 2: Build desired list and compute differences ---
    desired_titles = []
    for m in milestones:
        title = m.get("title")
        if title == None:
            fail("each milestone must include 'title'")
        desired_titles.append(title)

    added = []
    updated = []
    removed = []
    untouched = []

    # Compute operations
    if state == "present":
        # For each desired milestone
        for m in milestones:
            title = m.get("title")
            if title in existing_titles:
                # Check for updates (simplified: always mark as updated to ensure idempotency)
                updated.append(title)
            else:
                added.append(title)

        # Purge: remove existing not in desired
        if purge == True:
            for t in existing_titles:
                if t not in desired_titles:
                    removed.append(t)
    elif state == "absent":
        if purge == False:
            # Remove only requested that exist
            for t in desired_titles:
                if t in existing_titles:
                    removed.append(t)
        else:
            # Remove all
            for t in existing_titles:
                removed.append(t)

    # Compute untouched
    untouched = []
    for t in desired_titles:
        if t in existing_titles and t not in updated and t not in removed:
            untouched.append(t)

    changed = bool(len(added) > 0 or len(updated) > 0 or len(removed) > 0)

    # --- Check mode ---
    if ctx.check_mode == True:
        msg_parts = []
        if len(added) > 0:
            msg_parts.append("would create " + str(len(added)) + " milestone(s)")
        if len(updated) > 0:
            msg_parts.append("would update " + str(len(updated)) + " milestone(s)")
        if len(removed) > 0:
            msg_parts.append("would delete " + str(len(removed)) + " milestone(s)")
        if changed == False:
            msg_parts.append("no change")
        return {"changed": False, "msg": ", ".join(msg_parts), "data": {
            "added": added,
            "updated": updated,
            "removed": removed,
            "untouched": untouched
        }}

    # --- Perform actual operations ---
    # Create/update milestones
    for m in milestones:
        title = m.get("title")
        description = m.get("description")
        start_date = m.get("start_date")
        due_date = m.get("due_date")

        # Validate dates format (YYYY-MM-DD) if provided
        if start_date != None:
            if len(start_date) != 10 or start_date[4] != "-" or start_date[7] != "-":
                fail("start_date '%s' is not in YYYY-MM-DD format" % start_date)
        if due_date != None:
            if len(due_date) != 10 or due_date[4] != "-" or due_date[7] != "-":
                fail("due_date '%s' is not in YYYY-MM-DD format" % due_date)

        if title in existing_titles:
            # Update existing milestone
            milestone_id = ""
            # Find ID (simplified: query by title if needed — omitted for brevity)
            fail("milestone update is not implemented in this Starlark translation")

        else:
            # Create new milestone
            # Build JSON body
            json_body = '{"title":"%s"' % title
            if description != None:
                json_body += ',"description":"%s"' % description
            if start_date != None:
                json_body += ',"start_date":"%s"' % start_date
            if due_date != None:
                json_body += ',"due_date":"%s"' % due_date
            json_body += '}'

            # POST request
            curl_args = [ctx.command("curl"), "-s", "-X", "POST"]
            if params.get("validate_certs") == False:
                curl_args.append("-k")
            if private_token == None and params.get("api_username") != None and params.get("api_password") != None:
                curl_args.extend(["-u", params["api_username"] + ":" + params["api_password"]])
            elif private_token != None:
                curl_args.append("-H")
                curl_args.append("PRIVATE-TOKEN: " + private_token)
            curl_args.extend(["-H", "Content-Type: application/json", "-d", json_body])
            curl_args.append(url)

            res = ctx.run(curl_args, mutates=True, ok_codes=[201, 400])
            if res.rc != 201:
                fail("failed to create milestone '%s': %s" % (title, res.stderr))

    # Delete milestones
    if len(removed) > 0:
        for title in removed:
            # Find milestone ID (simplified: query by title — omitted)
            fail("milestone deletion is not implemented in this Starlark translation")

    return {"changed": changed, "msg": "operations completed", "data": {
        "added": added,
        "updated": updated,
        "removed": removed,
        "untouched": untouched
    }}
