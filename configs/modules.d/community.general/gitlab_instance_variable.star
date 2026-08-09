def main(ctx, params):
    # Auth parameters
    api_url = params.get("api_url")
    api_token = params.get("api_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    api_oauth_token = params.get("api_oauth_token")
    api_job_token = params.get("api_job_token")
    ca_path = params.get("ca_path")
    validate_certs = params.get("validate_certs", True)

    # Module parameters
    state = params.get("state", "present")
    purge = params.get("purge", False)
    variables = params.get("variables", [])

    # Validate authentication method
    auth_count = 0
    if api_token != None:
        auth_count += 1
    if api_oauth_token != None:
        auth_count += 1
    if api_job_token != None:
        auth_count += 1
    if api_username != None:
        auth_count += 1

    if auth_count == 0:
        fail("one of api_token, api_oauth_token, api_job_token, api_username is required")
    if auth_count > 1:
        fail("only one of api_token, api_oauth_token, api_job_token, api_username can be used")

    if api_username != None and api_password == None:
        fail("api_password is required when using api_username")

    if state == "present":
        for var in variables:
            if var.get("value") == None:
                fail("value parameter is required when state=present for variable: " + var.get("name", "<unnamed>"))

    # Normalize variables
    normalized_vars = []
    for var in variables:
        v = dict(var)  # copy
        v["key"] = v.pop("name")
        v["value"] = str(v.get("value", ""))
        if v.get("masked") == None:
            v["masked"] = False
        if v.get("protected") == None:
            v["protected"] = False
        if v.get("variable_type") == None:
            v["variable_type"] = "env_var"
        normalized_vars.append(v)

    # Build curl command to list existing variables
    auth_header = ""
    if api_token != None:
        auth_header = "-H \"PRIVATE-TOKEN: " + api_token + "\""
    elif api_oauth_token != None:
        auth_header = "-H \"Authorization: Bearer " + api_oauth_token + "\""
    elif api_job_token != None:
        auth_header = "-H \"JOB-TOKEN: " + api_job_token + "\""
    elif api_username != None:
        auth_header = "-u \"" + api_username + ":" + api_password + "\""

    verify_ssl = ""
    if not validate_certs:
        verify_ssl = "-k"
    elif ca_path != None:
        verify_ssl = "--cacert \"" + ca_path + "\""

    base_cmd = ["curl", "-s", "-X", "GET"]
    if auth_header != "":
        base_cmd.extend(auth_header.split())
    if verify_ssl != "":
        base_cmd.extend(verify_ssl.split())
    base_cmd.append(api_url.rstrip("/") + "/api/v4/instance/variables")

    # List existing variables (read-only)
    res = ctx.run(base_cmd, mutates=False)
    if res.rc != 0:
        fail("failed to list GitLab instance variables: " + res.stderr)

    # Parse JSON using simple string parsing — we assume the response is a JSON array of objects.
    # Since Starlark has no built-in JSON parser, use ctx.json_decode if available; otherwise, fail.
    if not hasattr(ctx, "json_decode"):
        fail("failed to decode JSON response from GitLab; ctx.json_decode not available")
    existing_list = ctx.json_decode(res.stdout)

    # Normalize existing variables
    existing_vars = []
    for var in existing_list:
        v = dict(var)
        v["value"] = str(v.get("value", ""))
        existing_vars.append(v)

    # Determine changes
    added = []
    updated = []
    removed = []
    untouched = []

    if state == "present":
        if ctx.check_mode:
            # Simulate comparison
            for nv in normalized_vars:
                found = False
                for ev in existing_vars:
                    if ev.get("key") == nv.get("key"):
                        found = True
                        if ev != nv:
                            updated.append(nv)
                        else:
                            untouched.append(nv)
                        break
                if not found:
                    added.append(nv)
        else:
            for nv in normalized_vars:
                existing_match = None
                for ev in existing_vars:
                    if ev.get("key") == nv.get("key"):
                        existing_match = ev
                        break

                if existing_match == None:
                    # Create
                    create_cmd = ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
                                  "-d", ctx.json_encode(nv)] + base_cmd[2:] + [api_url.rstrip("/") + "/api/v4/instance/variables"]
                    res = ctx.run(create_cmd, mutates=True)
                    if res.skipped:
                        added.append(nv)
                        continue
                    if res.rc != 0:
                        fail("failed to create variable " + nv.get("key") + ": " + res.stderr)
                    added.append(nv)
                else:
                    # Update if different
                    if existing_match != nv:
                        # Delete then create
                        delete_cmd = ["curl", "-s", "-X", "DELETE"] + base_cmd[2:] + [api_url.rstrip("/") + "/api/v4/instance/variables/" + nv.get("key")]
                        res = ctx.run(delete_cmd, mutates=True)
                        if res.skipped:
                            updated.append(nv)
                            continue
                        if res.rc != 0:
                            fail("failed to delete variable " + nv.get("key") + " before update: " + res.stderr)
                        create_cmd2 = ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
                                       "-d", ctx.json_encode(nv)] + base_cmd[2:] + [api_url.rstrip("/") + "/api/v4/instance/variables"]
                        res2 = ctx.run(create_cmd2, mutates=True)
                        if res2.skipped:
                            updated.append(nv)
                            continue
                        if res2.rc != 0:
                            fail("failed to update variable " + nv.get("key") + ": " + res2.stderr)
                        updated.append(nv)
                    else:
                        untouched.append(nv)

            if purge:
                # Refetch after creations/updates (in real mode only)
                if not ctx.check_mode:
                    res = ctx.run(base_cmd, mutates=False)
                    if res.rc != 0:
                        fail("failed to refetch GitLab instance variables after changes: " + res.stderr)
                    existing_vars = ctx.json_decode(res.stdout)
                    # Normalize again
                    existing_vars = []
                    for v in existing_vars:
                        v2 = dict(v)
                        v2["value"] = str(v2.get("value", ""))
                        existing_vars.append(v2)

                for ev in existing_vars:
                    found = False
                    for nv in normalized_vars:
                        if ev.get("key") == nv.get("key"):
                            found = True
                            break
                    if not found:
                        if ctx.check_mode:
                            removed.append(ev)
                        else:
                            del_cmd = ["curl", "-s", "-X", "DELETE"] + base_cmd[2:] + [api_url.rstrip("/") + "/api/v4/instance/variables/" + ev.get("key")]
                            res = ctx.run(del_cmd, mutates=True)
                            if res.skipped:
                                removed.append(ev)
                                continue
                            if res.rc != 0:
                                fail("failed to remove variable " + ev.get("key") + ": " + res.stderr)
                            removed.append(ev)

    elif state == "absent":
        if purge:
            # Delete all
            if ctx.check_mode:
                removed.extend(existing_vars)
            else:
                for ev in existing_vars:
                    del_cmd = ["curl", "-s", "-X", "DELETE"] + base_cmd[2:] + [api_url.rstrip("/") + "/api/v4/instance/variables/" + ev.get("key")]
                    res = ctx.run(del_cmd, mutates=True)
                    if res.skipped:
                        removed.append(ev)
                        continue
                    if res.rc != 0:
                        fail("failed to delete variable " + ev.get("key") + ": " + res.stderr)
                    removed.append(ev)
        else:
            # Delete only requested variables
            keys_to_delete = [v.get("key") for v in normalized_vars]
            if ctx.check_mode:
                for ev in existing_vars:
                    if ev.get("key") in keys_to_delete:
                        removed.append(ev)
            else:
                for ev in existing_vars:
                    if ev.get("key") in keys_to_delete:
                        del_cmd = ["curl", "-s", "-X", "DELETE"] + base_cmd[2:] + [api_url.rstrip("/") + "/api/v4/instance/variables/" + ev.get("key")]
                        res = ctx.run(del_cmd, mutates=True)
                        if res.skipped:
                            removed.append(ev)
                            continue
                        if res.rc != 0:
                            fail("failed to delete variable " + ev.get("key") + ": " + res.stderr)
                        removed.append(ev)

    # Build return value
    added_names = [x.get("key") for x in added]
    updated_names = [x.get("key") for x in updated]
    removed_names = [x.get("key") for x in removed]
    untouched_names = [x.get("key") for x in untouched]

    changed = len(added_names) + len(updated_names) + len(removed_names) > 0

    data = {
        "added": added_names,
        "updated": updated_names,
        "removed": removed_names,
        "untouched": untouched_names
    }

    return {"changed": changed, "msg": "GitLab instance variables updated", "data": data}
