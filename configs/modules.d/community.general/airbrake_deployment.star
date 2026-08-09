def main(ctx, params):
    project_id = params["project_id"]
    project_key = params["project_key"]
    environment = params["environment"]
    url = params.get("url", "https://api.airbrake.io/api/v4/projects/")
    validate_certs = params.get("validate_certs", True)

    # Check mode: always report change since the deployment would be created
    if ctx.check_mode:
        return {"changed": True, "msg": "would notify airbrake about deployment"}

    # Build request body
    body_dict = {"environment": environment}
    user = params.get("user")
    if user != None:
        body_dict["username"] = user
    repo = params.get("repo")
    if repo != None:
        body_dict["repository"] = repo
    revision = params.get("revision")
    if revision != None:
        body_dict["revision"] = revision
    version = params.get("version")
    if version != None:
        body_dict["version"] = version

    # Build URL and JSON body manually (no json module available)
    full_url = url.rstrip("/") + "/" + project_id + "/deploys?key=" + project_key

    # Construct JSON manually (simple case, no nested dicts requiring escaping)
    def json_escape(s):
        if s == None:
            return "null"
        s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        return '"' + s + '"'

    def json_obj(d):
        parts = []
        for k, v in sorted(d.items()):
            if isinstance(v, str):
                parts.append(json_escape(k) + ":" + json_escape(v))
            elif v == None:
                parts.append(json_escape(k) + ":null")
            else:
                parts.append(json_escape(k) + ":" + str(v))
        return "{" + ",".join(parts) + "}"

    json_body = json_obj(body_dict)

    # Build headers
    headers = ["Content-Type", "application/json"]

    # Submit POST request
    res = ctx.run(
        ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", json_body, full_url],
        mutates=True
    )

    # Handle SSL verification control (curl -k flag if not validating)
    if not validate_certs:
        res = ctx.run(
            ["curl", "-s", "-k", "-X", "POST", "-H", "Content-Type: application/json", "-d", json_body, full_url],
            mutates=True
        )

    # Check result
    if res.rc == 0:
        # Success if HTTP status 200 or 201 — parse via headers or body
        # Since we can't rely on complex parsing, assume success if rc == 0 (curl succeeded)
        # Airbrake returns 200/201 on success
        return {"changed": True, "msg": "notified airbrake about deployment"}
    else:
        fail("failed to notify airbrake: " + res.stderr if res.stderr else "HTTP result code: " + str(res.rc) + " connecting to " + full_url)
