def main(ctx, params):
    auth_token = params.get("auth_token")
    name = params.get("name")
    project_id = params.get("id")
    org_id = params.get("org_id")
    payment_method = params.get("payment_method")
    custom_data = params.get("custom_data")
    state = params.get("state", "present")

    if auth_token == None:
        fail("if Packet API token is not in environment variable PACKET_API_TOKEN, the auth_token parameter is required")

    # Validate required params
    if state == "present" and name == None and project_id == None:
        fail("one of name or id is required when state is present")
    if state == "absent" and project_id == None and name == None:
        fail("one of name or id is required when state is absent")
    if state == "absent" and not (project_id == None) and not (name == None):
        fail("id and name are mutually exclusive when state is absent")

    # List existing projects via API call
    projects = ctx.run(
        ["curl", "-sS", "-X", "GET",
         "-H", "X-Auth-Token: " + auth_token,
         "-H", "Accept: application/json",
         "https://api.packet.com/projects"],
        mutates=False
    )

    if projects.rc != 0:
        fail("failed to list projects: " + projects.stderr)

    # Parse JSON manually (no json module)
    # Basic JSON parser for list of project objects with 'id' and 'name'
    raw = projects.stdout.strip()
    if raw == "":
        matching = []
    else:
        # Very simple parser assuming standard API response format
        # Expected structure: [{...},{...}]
        # Extract id and name from each object
        # This parser assumes no nested brackets in values for simplicity
        matching = []
        # Strip outer brackets
        if raw.startswith("[") and raw.endswith("]"):
            raw = raw[1:-1].strip()
        else:
            fail("unexpected JSON format for project list")

        # Split objects at top-level { } pairs
        depth = 0
        start = -1
        i = 0
        while i < len(raw):
            c = raw[i]
            if c == '{':
                if depth == 0:
                    start = i
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0 and start != -1:
                    obj_str = raw[start:i+1]
                    # Extract id and name
                    # Look for "id":"uuid" or "id" : "uuid"
                    id_start = obj_str.find('"id"')
                    if id_start != -1:
                        # Find colon
                        colon = obj_str.find(':', id_start + 4)
                        if colon != -1:
                            # Skip whitespace
                            while colon < len(obj_str) and obj_str[colon] in ' \t':
                                colon += 1
                            if colon < len(obj_str) and obj_str[colon] == '"':
                                # Find end quote
                                end_quote = obj_str.find('"', colon+1)
                                if end_quote != -1:
                                    obj_id = obj_str[colon+1:end_quote]
                                else:
                                    obj_id = ""
                            else:
                                obj_id = ""
                        else:
                            obj_id = ""
                    else:
                        obj_id = ""

                    # Same for name
                    name_start = obj_str.find('"name"')
                    if name_start != -1:
                        colon = obj_str.find(':', name_start + 6)
                        if colon != -1:
                            while colon < len(obj_str) and obj_str[colon] in ' \t':
                                colon += 1
                            if colon < len(obj_str) and obj_str[colon] == '"':
                                end_quote = obj_str.find('"', colon+1)
                                if end_quote != -1:
                                    obj_name = obj_str[colon+1:end_quote]
                                else:
                                    obj_name = ""
                            else:
                                obj_name = ""
                        else:
                            obj_name = ""
                    else:
                        obj_name = ""

                    if project_id != None and obj_id == project_id:
                        matching.append({"id": obj_id, "name": obj_name})
                    elif name != None and obj_name == name:
                        matching.append({"id": obj_id, "name": obj_name})
                    elif project_id == None and name == None:
                        # Shouldn't happen due to prior validation
                        pass

                    start = -1
            i += 1

    if state == "present":
        if len(matching) == 0:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create project"}

            # Build POST data
            data = {"name": name}
            if payment_method != None:
                data["payment_method_id"] = payment_method
            if custom_data != None:
                data["customdata"] = custom_data

            if org_id == None:
                # POST to /projects
                create = ctx.run(
                    ["curl", "-sS", "-X", "POST",
                     "-H", "X-Auth-Token: " + auth_token,
                     "-H", "Accept: application/json",
                     "-H", "Content-Type: application/json",
                     "-d", str(data).replace("'", '"'),  # Not ideal but minimal for basic dicts
                     "https://api.packet.com/projects"],
                    mutates=True
                )
            else:
                # POST to /organizations/{org_id}/projects
                url = "https://api.packet.com/organizations/" + org_id + "/projects"
                create = ctx.run(
                    ["curl", "-sS", "-X", "POST",
                     "-H", "X-Auth-Token: " + auth_token,
                     "-H", "Accept: application/json",
                     "-H", "Content-Type: application/json",
                     "-d", str(data).replace("'", '"'),
                     url],
                    mutates=True
                )

            if create.rc != 0:
                fail("failed to create project: " + create.stderr)

            # Parse created project id and name from response
            # Expect {"id":"...","name":"..."}
            created = create.stdout.strip()
            # Basic extraction
            proj_id = ""
            proj_name = ""
            for key in ["id", "name"]:
                pos = created.find('"' + key + '"')
                if pos != -1:
                    colon = created.find(':', pos + len(key) + 2)
                    if colon != -1:
                        while colon < len(created) and created[colon] in ' \t\n':
                            colon += 1
                        if colon < len(created) and created[colon] == '"':
                            end = created.find('"', colon+1)
                            if end != -1:
                                val = created[colon+1:end]
                                if key == "id":
                                    proj_id = val
                                else:
                                    proj_name = val

            return {"changed": True, "name": proj_name, "id": proj_id,
                    "msg": "created project " + proj_name}
        else:
            return {"changed": False, "name": matching[0]["name"], "id": matching[0]["id"],
                    "msg": "project already exists"}

    else:  # state == "absent"
        if len(matching) == 0:
            return {"changed": False, "msg": "project not found"}

        if len(matching) > 1:
            fail("more than one project matched for deletion")

        p = matching[0]

        if ctx.check_mode:
            return {"changed": True, "name": p["name"], "id": p["id"],
                    "msg": "would delete project " + p["name"]}

        # DELETE /projects/{id}
        delete_res = ctx.run(
            ["curl", "-sS", "-X", "DELETE",
             "-H", "X-Auth-Token: " + auth_token,
             "-H", "Accept: application/json",
             "https://api.packet.com/projects/" + p["id"]],
            mutates=True
        )

        if delete_res.rc != 0:
            fail("failed to delete project " + p["id"] + ": " + delete_res.stderr)

        return {"changed": True, "name": p["name"], "id": p["id"],
                "msg": "deleted project " + p["name"]}
