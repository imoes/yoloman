def main(ctx, params):
    # Required params
    api_host = params["api_host"]
    api_user = params["api_user"]
    state = params.get("state", "present")

    # Optional params with defaults
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    node = params.get("node")
    storage = params.get("storage", "local")
    content_type = params.get("content_type", "vztmpl")
    timeout = params.get("timeout", 30)
    force = params.get("force", False)
    src = params.get("src")
    template = params.get("template")
    validate_certs = params.get("validate_certs", False)

    # Validation: for state=present, src or template must be provided
    if state == "present":
        content_type = params.get("content_type", "vztmpl")
        if not src and content_type == "vztmpl":
            if not template:
                fail("template param for downloading appliance template is mandatory when state is present and content_type is vztmpl")
        elif not src:
            fail("src param to uploading template file is mandatory when state is present")
        elif content_type != "vztmpl":
            fail("content_type must be vztmpl when uploading file (only vztmpl is supported in this module)")

    # For state=absent, template is required
    if state == "absent" and not template:
        fail("template is required when state is absent")

    # Build base URL (simplified: assume http://host:8006/api2/json)
    base_url = "http://%s:8006/api2/json" % api_host
    if validate_certs == True:
        fail("validate_certs=true is not supported. Use validate_certs=false for self-signed certs.")

    # Auth: build headers using api_user and either password or token
    if api_password != None:
        auth_header = "PVEAuthCookie=%s:%s" % (api_user, api_password)
    elif api_token_id != None:
        if api_token_secret == None:
            fail("api_token_secret is required when api_token_id is provided")
        auth_header = "PVEAPIToken=%s#%s:%s" % (api_user, api_token_id, api_token_secret)
    else:
        fail("either api_password or api_token_id must be provided")

    headers = {
        "Authorization": auth_header
    }

    # Helper: perform GET request
    def proxmox_get(path):
        return ctx.run(
            ["curl", "-s", "-k", "-X", "GET", base_url + path, "-H", "Content-Type: application/json", "-H", headers["Authorization"]],
            mutates=False
        )

    # Helper: perform POST request
    def proxmox_post(path, form_data=None, file_path=None):
        if form_data == None:
            form_data = []
        cmd = ["curl", "-s", "-k", "-X", "POST", base_url + path, "-H", "Content-Type: application/json", "-H", headers["Authorization"]]
        # Build form args
        for k, v in form_data:
            cmd.extend(["-F", "%s=%s" % (k, v)])
        if file_path != None:
            cmd.extend(["-F", "filename=@%s" % file_path])
        return ctx.run(cmd, mutates=True)

    # Helper: perform DELETE request
    def proxmox_delete(path):
        return ctx.run(
            ["curl", "-s", "-k", "-X", "DELETE", base_url + path, "-H", "Content-Type: application/json", "-H", headers["Authorization"]],
            mutates=True
        )

    # Helper: get list of templates
    def get_template(node, storage, content_type, template):
        volid = "%s:%s/%s" % (storage, content_type, template)
        res = proxmox_get("/nodes/%s/storage/%s/content" % (node, storage))
        if res.rc != 0:
            fail("Failed to list templates on node %s, storage %s: %s" % (node, storage, res.stderr))
        # Parse JSON manually (simple list of dicts with 'volid' keys)
        lines = res.stdout.strip().split("\n")
        # Expect JSON array like [{"volid":"local:vztmpl/foo.tar.gz"}, ...]
        # Use basic parsing: find all "volid":"..." values
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if '"volid"' in line:
                start = line.find('"volid"') + len('"volid"') + 2  # skip ": "
                end = line.find('"', start)
                if start != -1 and end != -1:
                    found_volid = line[start:end]
                    if found_volid == volid:
                        return True
            i += 1
        return False

    # Helper: wait for task completion (simplified polling)
    def wait_for_task(node, task_id, timeout):
        while timeout > 0:
            res = proxmox_get("/nodes/%s/tasks/%s/status" % (node, task_id))
            if res.rc != 0:
                timeout -= 1
                continue
            # Look for "status": "running" or "status": "stopped"
            if '"status"' in res.stdout:
                if '"stopped"' in res.stdout or '"stopped"' in res.stderr or "stopped" in res.stdout or "stopped" in res.stderr:
                    # Check success
                    if '"exitstatus"' in res.stdout or '"exitstatus"' in res.stderr or "OK" in res.stdout or "OK" in res.stderr:
                        return True
                    else:
                        fail("Task %s failed" % task_id)
            timeout -= 1
        fail("Reached timeout while waiting for task %s" % task_id)

    # --- Main logic ---

    if state == "present":
        # Determine template name (from src or template param)
        if src != None:
            # Upload file
            template_name = src.rsplit("/", 1)[-1]
        else:
            # Download appliance template
            if content_type != "vztmpl":
                fail("content_type must be vztmpl for downloading appliance template")
            template_name = template

        # Check if template already exists (skip if force=False)
        if get_template(node, storage, content_type, template_name) and not force:
            return {"changed": False, "msg": "template with volid=%s:%s/%s already exists" % (storage, content_type, template_name)}

        # If upload
        if src != None:
            # Check src exists
            if not ctx.file_exists(src):
                fail("template file on path %s not exists" % src)

            # Build form args
            form_data = [("content", content_type), ("filename", "@%s" % src), ("storage", storage)]
            res = proxmox_post("/nodes/%s/storage/%s/upload" % (node, storage), form_data)
            if res.skipped:
                return {"changed": True, "msg": "would upload template %s" % template_name}
            if res.rc != 0:
                fail("Uploading template %s failed: %s" % (src, res.stderr))
            # Parse task ID from JSON response (simplified)
            # Expected: {"data": {"taskid": "UPID:node:...:..."}}
            if '"taskid"' in res.stdout or '"taskid"' in res.stderr:
                start = res.stdout.find('"taskid"')
                if start != -1:
                    start = res.stdout.find('"', start + len('"taskid"') + 2)
                    end = res.stdout.find('"', start + 1)
                    if start != -1 and end != -1:
                        task_id = res.stdout[start + 1:end]
                        if not wait_for_task(node, task_id, timeout):
                            fail("Upload timeout")
            return {"changed": True, "msg": "template with volid=%s:%s/%s uploaded" % (storage, content_type, template_name)}

        # Else: download appliance template
        else:
            form_data = [("storage", storage), ("template", template)]
            res = proxmox_post("/nodes/%s/aplinfo" % node, form_data)
            if res.skipped:
                return {"changed": True, "msg": "would download template %s" % template}
            if res.rc != 0:
                fail("Downloading template %s failed: %s" % (template, res.stderr))
            # Parse task ID
            if '"taskid"' in res.stdout or '"taskid"' in res.stderr:
                start = res.stdout.find('"taskid"')
                if start != -1:
                    start = res.stdout.find('"', start + len('"taskid"') + 2)
                    end = res.stdout.find('"', start + 1)
                    if start != -1 and end != -1:
                        task_id = res.stdout[start + 1:end]
                        if not wait_for_task(node, task_id, timeout):
                            fail("Download timeout")
            return {"changed": True, "msg": "template with volid=%s:%s/%s downloaded" % (storage, content_type, template)}

    elif state == "absent":
        # Check exists first
        if not get_template(node, storage, content_type, template):
            return {"changed": False, "msg": "template with volid=%s:%s/%s is already deleted" % (storage, content_type, template)}

        # Delete
        volid = "%s:%s/%s" % (storage, content_type, template)
        res = proxmox_delete("/nodes/%s/storage/%s/content/%s" % (node, storage, volid))
        if res.skipped:
            return {"changed": True, "msg": "would delete template %s" % template}
        if res.rc != 0:
            fail("Deleting template %s failed: %s" % (template, res.stderr))

        # Wait for deletion (simplified: re-check existence)
        while timeout > 0:
            if not get_template(node, storage, content_type, template):
                return {"changed": True, "msg": "template with volid=%s:%s/%s deleted" % (storage, content_type, template)}
            timeout -= 1

        fail("Reached timeout while waiting for deleting template.")
