def main(ctx, params):
    # Required: exactly one of project/group
    project = params.get("project")
    group = params.get("group")
    if not project and not group:
        fail("either 'project' or 'group' must be specified")
    if project and group:
        fail("only one of 'project' or 'group' can be specified")

    # Authentication: exactly one of api_username, api_token, api_oauth_token, api_job_token
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    api_token = params.get("api_token")
    api_oauth_token = params.get("api_oauth_token")
    api_job_token = params.get("api_job_token")
    
    has_basic_auth = api_username != None
    has_token = api_token != None
    has_oauth = api_oauth_token != None
    has_job_token = api_job_token != None
    
    auth_count = sum([has_basic_auth, has_token, has_oauth, has_job_token])
    if auth_count == 0:
        fail("one of 'api_username', 'api_token', 'api_oauth_token', or 'api_job_token' is required")
    if auth_count > 1:
        fail("only one authentication method is allowed")

    # Basic auth requires password
    if has_basic_auth and api_password == None:
        fail("'api_password' is required when using 'api_username'")

    # State and purge
    state = params.get("state", "present")
    if state not in ["present", "absent"]:
        fail("state must be 'present' or 'absent'")
    purge = params.get("purge", False)
    labels = params.get("labels", [])

    # Build API URL and auth headers
    api_url = params.get("api_url", "").rstrip("/")
    if not api_url:
        fail("api_url is required")
    
    ca_path = params.get("ca_path")
    validate_certs = params.get("validate_certs", True)

    # Build headers
    headers = ["-H", "Content-Type: application/json"]
    if api_username != None:
        auth_str = api_username + ":" + api_password
        # Encode base64 manually (simple implementation)
        b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        def base64_encode(s):
            result = ""
            i = 0
            while i < len(s):
                c1 = ord(s[i]); c2 = ord(s[i+1]) if i+1 < len(s) else 0; c3 = ord(s[i+2]) if i+2 < len(s) else 0
                result += b64_chars[c1 >> 2]
                result += b64_chars[((c1 & 3) << 4) | (c2 >> 4)]
                if i+1 < len(s):
                    result += b64_chars[((c2 & 15) << 2) | (c3 >> 6)]
                else:
                    result += "="
                if i+2 < len(s):
                    result += b64_chars[c3 & 63]
                else:
                    result += "="
                i += 3
            return result
        headers += ["-H", "Authorization: Basic " + base64_encode(auth_str)]
    elif api_token != None:
        headers += ["-H", "PRIVATE-TOKEN: " + api_token]
    elif api_oauth_token != None:
        headers += ["-H", "Authorization: Bearer " + api_oauth_token]
    elif api_job_token != None:
        headers += ["-H", "JOB-TOKEN: " + api_job_token]

    if not validate_certs:
        headers += ["-k"]

    # Determine target: project or group
    target_type = ""
    target_path = ""
    if project:
        target_type = "project"
        target_path = project.replace("/", "%2F")
    else:
        target_type = "group"
        target_path = group.replace("/", "%2F")

    base_url = api_url + "/api/v4/" + target_type + "/" + target_path + "/labels"

    # Helper: list current labels
    def list_labels():
        url = base_url + "?per_page=100"
        label_list = []
        while url:
            # Get list of labels
            res = ctx.run(["curl", "-s", "-S"] + headers + ["-X", "GET", url], mutates=False)
            if res.rc != 0:
                fail("failed to list labels: " + res.stderr)
            # Parse JSON manually (no json module)
            data = res.stdout
            labels_list = []
            i = 0
            while i < len(data):
                # Simple parser for list of dicts
                while i < len(data) and data[i] not in "[{":
                    i += 1
                if i >= len(data):
                    break
                if data[i] == "[":
                    i += 1
                    while i < len(data) and data[i] != "[" and data[i] != "{":
                        i += 1
                    if i < len(data) and data[i] == "{":
                        obj = ""
                        brace = 0
                        while i < len(data):
                            obj += data[i]
                            if data[i] == "{":
                                brace += 1
                            elif data[i] == "}":
                                brace -= 1
                            if brace == 0:
                                break
                            i += 1
                        if obj:
                            # Extract 'name'
                            name_start = obj.find('"name"')
                            if name_start != -1:
                                name_start = obj.find('"', name_start+6)+1
                                name_end = obj.find('"', name_start)
                                if name_start != -1 and name_end != -1:
                                    labels_list.append(obj[name_start:name_end])
                    i += 1
                    while i < len(data) and data[i] != "]":
                        i += 1
                    i += 1
                    break
                i += 1
            # Simple pagination: find next page link (if any)
            next_link = ""
            if '"links":' in data:
                links_idx = data.find('"links":', data.find("[]")) if len(label_list) == 0 else data.find('"links":')
                if links_idx != -1:
                    # Find next page url
                    next_idx = data.find('"next":', links_idx)
                    if next_idx != -1:
                        next_url_start = data.find('"', next_idx+len('"next":'))+1
                        next_url_end = data.find('"', next_url_start)
                        if next_url_start != -1 and next_url_end != -1:
                            next_link = data[next_url_start:next_url_end]
            label_list.extend(labels_list)
            url = next_link if next_link.startswith("http") else (api_url + next_link) if next_link.startswith("/") else (api_url + "/" + next_link) if next_link and next_link[0] != "/" else ""
        return label_list

    current_names = list_labels()

    # Helper: create label
    def create_label(label):
        url = base_url
        name = label.get("name")
        color = label.get("color")
        if not color:
            fail("color is required for new label: " + name)
        desc = label.get("description", "")
        priority = label.get("priority")
        # Build JSON manually
        json_body = '{"name":"' + name + '","color":"' + color + '"'
        if desc:
            json_body += ',"description":"' + desc + '"'
        if priority != None:
            json_body += ',"priority":' + str(int(priority))
        json_body += '}'
        res = ctx.run(["curl", "-s", "-S"] + headers + ["-X", "POST", "-d", json_body, url], mutates=True)
        if res.rc != 0:
            fail("failed to create label " + name + ": " + res.stderr)
        # Extract name from response
        return name

    # Helper: update label (by name)
    def update_label(label):
        name = label.get("name")
        new_name = label.get("new_name")
        desc = label.get("description")
        priority = label.get("priority")

        # Get existing label
        res = ctx.run(["curl", "-s", "-S"] + headers + ["-X", "GET", base_url + "/" + name], mutates=False)
        if res.rc != 0:
            fail("failed to get label " + name + " for update: " + res.stderr)
        # Check if update needed
        if res.stdout.find(name) == -1:
            fail("label " + name + " not found for update")
        
        # Prepare update data
        updates = []
        if new_name:
            updates.append('"new_name":"' + new_name + '"')
        if desc != None:
            updates.append('"description":"' + desc + '"')
        if priority != None:
            updates.append('"priority":' + str(int(priority)))
        if not updates:
            return name  # no change

        update_body = "{" + ",".join(updates) + "}"
        res = ctx.run(["curl", "-s", "-S"] + headers + ["-X", "PUT", "-d", update_body, base_url + "/" + name], mutates=True)
        if res.rc != 0:
            fail("failed to update label " + name + ": " + res.stderr)
        return new_name if new_name else name

    # Helper: delete label by name
    def delete_label(name):
        res = ctx.run(["curl", "-s", "-S"] + headers + ["-X", "DELETE", base_url + "/" + name], mutates=True)
        if res.rc != 0:
            fail("failed to delete label " + name + ": " + res.stderr)
        return name

    # Determine changes
    added = []
    updated = []
    removed = []
    untouched = []

    if state == "present":
        # Check for labels to add or update
        requested = labels
        requested_names = [x.get("name") for x in requested]
        
        for lab in requested:
            name = lab.get("name")
            if name in current_names:
                # Check if update needed
                needs_update = False
                if lab.get("new_name") and lab.get("new_name") != name:
                    needs_update = True
                if lab.get("description") != None and lab.get("description") != "":
                    needs_update = True
                if lab.get("priority") != None:
                    needs_update = True
                if needs_update:
                    updated.append(update_label(lab))
                else:
                    untouched.append(name)
            else:
                # Add new
                added.append(create_label(lab))

        # Purge: delete labels not in requested list (only when not in check_mode)
        if purge and not ctx.check_mode:
            for name in current_names:
                if name not in requested_names:
                    removed.append(delete_label(name))
        elif purge and ctx.check_mode:
            for name in current_names:
                if name not in requested_names:
                    removed.append(name)

    elif state == "absent":
        if purge:
            # Delete all current labels
            for name in current_names:
                removed.append(delete_label(name))
        else:
            # Delete only requested labels
            requested_names = [x.get("name") for x in labels]
            for name in current_names:
                if name in requested_names:
                    removed.append(delete_label(name))
                else:
                    untouched.append(name)

    # Return results
    changed = len(added) > 0 or len(updated) > 0 or len(removed) > 0
    
    msg = ""
    if changed:
        msg = "labels modified: added=" + str(len(added)) + ", updated=" + str(len(updated)) + ", removed=" + str(len(removed))
    else:
        msg = "labels unchanged: untouched=" + str(len(untouched))

    if ctx.check_mode:
        return {"changed": True, "msg": msg, "data": {"added": added, "updated": updated, "removed": removed, "untouched": untouched}}
    
    return {"changed": changed, "msg": msg, "data": {"added": added, "updated": updated, "removed": removed, "untouched": untouched}}
