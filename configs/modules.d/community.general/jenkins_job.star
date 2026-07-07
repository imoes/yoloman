def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    config = params.get("config")
    enabled = params.get("enabled")
    user = params.get("user")
    password = params.get("password")
    token = params.get("token")
    url = params.get("url", "http://localhost:8080")
    validate_certs = params.get("validate_certs", True)

    # Validate mutually exclusive parameters
    if password != None and token != None:
        fail("params 'password' and 'token' are mutually exclusive")
    if config != None and enabled != None:
        fail("params 'config' and 'enabled' are mutually exclusive")

    # Prepare auth header string without imports
    auth_header = ""
    if user:
        if password:
            # Basic auth: base64(user:password) computed externally if needed
            fail("password authentication requires external base64 computation - use token instead")
        elif token:
            # Token auth: base64(token:token) - same limitation
            fail("token authentication requires external base64 computation - use password instead")
        else:
            fail("user provided without password or token")

    headers = ["-H", "Content-Type: text/xml"]
    if auth_header:
        headers.extend(["-H", auth_header])
    if not validate_certs:
        headers.append("-k")

    def job_exists():
        res = ctx.run(["curl", "-s", "-X", "GET"] + headers + [url + "/job/" + name + "/api/json"], mutates=False)
        return res.rc == 0

    def get_current_config():
        res = ctx.run(["curl", "-s", "-X", "GET"] + headers + [url + "/job/" + name + "/config.xml"], mutates=False)
        if res.rc != 0:
            return None
        return res.stdout

    def job_status():
        res = ctx.run(["curl", "-s", "-X", "GET"] + headers + [url + "/job/" + name + "/api/json"], mutates=False)
        if res.rc != 0:
            return "absent"
        stdout = res.stdout
        if '"disabled"' in stdout:
            return "disabled"
        if '"color"' in stdout:
            return "enabled"
        return "absent"

    def enable_job():
        res = ctx.run(["curl", "-s", "-X", "POST"] + headers + [url + "/job/" + name + "/enable"], mutates=True)
        return res

    def disable_job():
        res = ctx.run(["curl", "-s", "-X", "POST"] + headers + [url + "/job/" + name + "/disable"], mutates=True)
        return res

    def create_job():
        cfg = config
        if cfg == None:
            fail("missing required param: config")
        res = ctx.run(["curl", "-s", "-X", "POST"] + headers + ["-d", cfg, url + "/createItem?name=" + name], mutates=True)
        return res

    def update_job():
        if config == None and enabled == None:
            fail("one of the following params is required on state=present: config,enabled")

        if config != None:
            current_cfg = get_current_config()
            if current_cfg != config:
                res = ctx.run(["curl", "-s", "-X", "POST"] + headers + ["-d", config, url + "/job/" + name + "/config.xml"], mutates=True)
                return res
        elif enabled != None:
            status = job_status()
            if status == "absent":
                fail("job does not exist; cannot change enabled state")
            if (enabled == True and status == "disabled") or (enabled == False and status != "disabled"):
                if enabled:
                    res = enable_job()
                else:
                    res = disable_job()
                return res
        return struct(rc=0, stdout="", stderr="", skipped=False)

    def delete_job():
        res = ctx.run(["curl", "-s", "-X", "POST"] + headers + [url + "/job/" + name + "/doDelete"], mutates=True)
        return res

    # State logic
    if state == "present":
        if job_exists():
            res = update_job()
            if res.rc != 0:
                fail("failed to update job: " + res.stderr)
            if res.skipped:
                return {"changed": False, "msg": name + " already in desired state"}
            return {"changed": True, "msg": "updated job " + name}
        else:
            if config == None:
                fail("missing required param: config")
            res = create_job()
            if res.rc != 0:
                fail("failed to create job: " + res.stderr)
            if res.skipped:
                return {"changed": True, "msg": "would create job " + name}
            return {"changed": True, "msg": "created job " + name}

    elif state == "absent":
        if not job_exists():
            return {"changed": False, "msg": "job " + name + " does not exist"}
        res = delete_job()
        if res.rc != 0:
            fail("failed to delete job: " + res.stderr)
        if res.skipped:
            return {"changed": True, "msg": "would delete job " + name}
        return {"changed": True, "msg": "deleted job " + name}

    fail("unsupported state: " + state)
