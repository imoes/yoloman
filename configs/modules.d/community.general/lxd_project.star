def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    new_name = params.get("new_name")
    config = params.get("config", {})
    description = params.get("description")
    merge_project = params.get("merge_project", False)
    url = params.get("url", "unix:/var/lib/lxd/unix.socket")
    snap_url = params.get("snap_url", "unix:/var/snap/lxd/common/lxd/unix.socket")
    client_key = params.get("client_key")
    client_cert = params.get("client_cert")
    trust_password = params.get("trust_password")

    # Determine socket path
    socket_path = url
    if url == "unix:/var/lib/lxd/unix.socket":
        if ctx.file_exists(snap_url.replace("unix:", "")):
            socket_path = snap_url

    # Helper: perform HTTP request using curl
    def lxd_do(method, path, json_body=None):
        cmd = ["curl", "-s", "-k", "--unix-socket", socket_path.replace("unix:", "")]
        if json_body != None:
            cmd.extend(["-X", method, "-d", str(json_body).replace("'", "\"")])
        else:
            cmd.extend(["-X", method])
        cmd.append("http://localhost/1.0" + path)
        res = ctx.run(cmd, ok_codes=[0, 404])
        if res.rc != 0:
            fail("LXD request failed: %s" % res.stderr)
        if res.stdout == "":
            return {"type": "error", "error_code": 404}
        # Simple JSON parse for LXD response
        # LXD response is typically: {"type":"sync","metadata":{...}}
        # We use basic string parsing to avoid external dependencies
        if res.stdout.find("\"type\":\"sync\"") != -1 and res.stdout.find("\"metadata\":{") != -1:
            # Extract metadata block
            start = res.stdout.find("\"metadata\":{")
            if start != -1:
                start += len("\"metadata\":{")
                # Naively extract until matching }
                depth = 1
                end = start
                while end < len(res.stdout) and depth > 0:
                    c = res.stdout[end]
                    if c == "{":
                        depth += 1
                    elif c == "}":
                        depth -= 1
                    if depth > 0:
                        end += 1
                meta_str = res.stdout[start:end]
                # Parse key-value pairs manually
                metadata = {}
                # Simple approach: split on quotes for common keys
                # Look for description and config
                if meta_str.find("\"description\":\"") != -1:
                    desc_start = meta_str.find("\"description\":\"") + len("\"description\":\"")
                    desc_end = meta_str.find("\"", desc_start)
                    metadata["description"] = meta_str[desc_start:desc_end]
                if meta_str.find("\"config\":{") != -1:
                    cfg_start = meta_str.find("\"config\":{") + len("\"config\":{")
                    # Extract config object similarly
                    depth_cfg = 1
                    end_cfg = cfg_start
                    while end_cfg < len(meta_str) and depth_cfg > 0:
                        c = meta_str[end_cfg]
                        if c == "{":
                            depth_cfg += 1
                        elif c == "}":
                            depth_cfg -= 1
                        if depth_cfg > 0:
                            end_cfg += 1
                    cfg_str = meta_str[cfg_start:end_cfg]
                    # Build dict manually
                    cfg_dict = {}
                    if cfg_str != "":
                        pairs = cfg_str.split(",")
                        for pair in pairs:
                            if pair.find(":") != -1:
                                k, v = pair.split(":", 1)
                                k = k.strip().strip("\"")
                                v = v.strip().strip("\"")
                                cfg_dict[k] = v
                    metadata["config"] = cfg_dict
                return {"type": "sync", "metadata": metadata}
        # Fallback for error responses
        return {"type": "error", "error_code": 404}

    # Get current project state
    project_path = "/1.0/projects/" + name
    resp = lxd_do("GET", project_path)
    old_state = "absent" if resp.get("type") == "error" else "present"
    old_metadata = resp.get("metadata", {}) if old_state == "present" else {}

    actions = []
    changed = False

    if state == "present":
        if old_state == "absent":
            # Create project
            if new_name != None:
                fail("new_name must not be set when the project does not exist")
            payload = {"name": name}
            if description != None:
                payload["description"] = description
            if config != {}:
                payload["config"] = config
            lxd_do("POST", "/1.0/projects", str(payload).replace("'", "\""))
            actions.append("create")
            changed = True
        else:
            # Project exists; handle rename and config update
            if new_name != None and new_name != name:
                lxd_do("POST", project_path, str({"name": new_name}).replace("'", "\""))
                actions.append("rename")
                name = new_name
                changed = True

            # Config handling
            old_config = old_metadata.get("config", {})
            old_desc = old_metadata.get("description", "")

            target_config = config
            target_desc = description

            if merge_project:
                # Merge: copy old_config and override with new
                merged = dict(old_config)
                for k, v in config.items():
                    merged[k] = v
                target_config = merged

            needs_update = False
            if description != None and old_desc != description:
                needs_update = True
            if config != {} and old_config != target_config:
                needs_update = True

            if needs_update:
                payload = {}
                if description != None:
                    payload["description"] = description
                payload["config"] = target_config
                lxd_do("PUT", project_path, str(payload).replace("'", "\""))
                actions.append("apply_projects_configs")
                changed = True

    elif state == "absent":
        if old_state == "present":
            if new_name != None:
                fail("new_name must not be set when the project exists and the state is absent")
            lxd_do("DELETE", project_path)
            actions.append("delete")
            changed = True

    msg = ""
    if state == "absent":
        msg = "project deleted"
    elif "rename" in actions:
        msg = "project renamed"
    elif "apply_projects_configs" in actions:
        msg = "project updated"
    elif "create" in actions:
        msg = "project created"
    else:
        msg = "project already present"

    return {
        "changed": changed,
        "msg": msg,
        "old_state": old_state,
        "actions": actions
    }
