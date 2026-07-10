def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    project = params.get("project")
    new_name = params.get("new_name")
    merge_profile = params.get("merge_profile", False)
    trust_password = params.get("trust_password")
    url = params.get("url", "unix:/var/lib/lxd/unix.socket")
    snap_url = params.get("snap_url", "unix:/var/snap/lxd/common/lxd/unix.socket")

    # Determine LXD socket URL
    socket_path = ""
    if url != "unix:/var/lib/lxd/unix.socket":
        socket_path = url.replace("unix:", "")
    else:
        snap_socket = snap_url.replace("unix:", "")
        socket_path = snap_socket if ctx.file_exists(snap_socket) else url.replace("unix:", "")

    # Prepare auth header if trust_password is provided
    auth_headers = {}
    if trust_password != None and trust_password != "":
        fail("lxd_profile with trust_password is not supported in this Starlark implementation")

    # Build query parameters for project
    project_param = ""
    if project != None and project != "":
        project_param = "?project=" + project

    # Get profile metadata
    get_url = "/1.0/profiles/" + name + project_param
    get_res = ctx.run([
        "curl", "-s", "-k", "--unix-socket", socket_path,
        "http://localhost" + get_url
    ])

    old_state = "absent"
    if get_res.rc == 0:
        old_state = "present"
    elif get_res.rc != 404:
        fail("failed to get profile: " + get_res.stderr)

    # Build desired config from params
    desired_config = {"name": name}
    if params.get("description") != None:
        desired_config["description"] = params["description"]
    if params.get("config") != None:
        desired_config["config"] = params["config"]
    if params.get("devices") != None:
        desired_config["devices"] = params["devices"]

    actions = []

    # Check mode
    if ctx.check_mode:
        changed = False
        if state == "absent" and old_state == "present":
            changed = True
        elif state == "present" and old_state == "absent":
            changed = True
        elif state == "present" and old_state == "present":
            # Simple change detection: name rename or config diff
            if new_name != None and new_name != name:
                changed = True
            else:
                # Assume change needed if any config param provided (no JSON parsing available)
                if params.get("config") != None or params.get("description") != None or params.get("devices") != None:
                    changed = True
        return {"changed": changed, "msg": "would " + ("delete" if state == "absent" else "manage") + " profile " + name, "actions": actions}

    # Real execution
    if state == "absent":
        if old_state == "present":
            if new_name != None:
                fail("new_name must not be set when the profile exists and the state is absent")
            # Delete profile
            del_res = ctx.run([
                "curl", "-s", "-k", "--unix-socket", socket_path,
                "-X", "DELETE",
                "http://localhost/1.0/profiles/" + name + project_param
            ])
            if del_res.rc != 0:
                fail("failed to delete profile: " + del_res.stderr)
            actions.append("delete")
    elif state == "present":
        if old_state == "absent":
            if new_name != None:
                fail("new_name must not be set when the profile does not exist and the state is present")
            # Create profile
            create_res = ctx.run([
                "curl", "-s", "-k", "--unix-socket", socket_path,
                "-X", "POST", "-d", str(desired_config).replace("'", '"'),
                "http://localhost/1.0/profiles" + project_param
            ])
            if create_res.rc != 0:
                fail("failed to create profile: " + create_res.stderr)
            actions.append("create")
        else:
            # Profile exists — rename if needed
            if new_name != None and new_name != name:
                rename_body = {"name": new_name}
                rename_res = ctx.run([
                    "curl", "-s", "-k", "--unix-socket", socket_path,
                    "-X", "POST", "-d", str(rename_body).replace("'", '"'),
                    "http://localhost/1.0/profiles/" + name + project_param
                ])
                if rename_res.rc != 0:
                    fail("failed to rename profile: " + rename_res.stderr)
                name = new_name
                actions.append("rename")

            # Apply config if changed
            # Since Starlark cannot parse JSON, we assume config changed if any config param provided
            if (params.get("config") != None or params.get("description") != None or params.get("devices") != None):
                if merge_profile:
                    fail("merge_profile is not supported in this Starlark implementation due to JSON parsing limitations")
                else:
                    # PUT profile
                    put_res = ctx.run([
                        "curl", "-s", "-k", "--unix-socket", socket_path,
                        "-X", "PUT", "-d", str(desired_config).replace("'", '"'),
                        "http://localhost/1.0/profiles/" + name + project_param
                    ])
                    if put_res.rc != 0:
                        fail("failed to update profile: " + put_res.stderr)
                    actions.append("apply_profile_configs")

    return {"changed": len(actions) > 0, "msg": "profile " + name + " " + ("deleted" if state == "absent" else "managed"), "actions": actions}
