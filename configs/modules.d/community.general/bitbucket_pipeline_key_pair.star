def main(ctx, params):
    # Extract parameters
    repository = params["repository"]
    workspace = params["workspace"]
    state = params["state"]
    public_key = params.get("public_key")
    private_key = params.get("private_key")
    client_id = params.get("client_id")
    client_secret = params.get("client_secret")
    password = params.get("password")
    user = params.get("user")

    # Validate required parameters for present state
    if state == "present":
        if public_key == None or private_key == None:
            fail("`public_key` and `private_key` are required when the `state` is `present`")

    # Build Bitbucket API base URL
    api_base = "https://api.bitbucket.org/2.0"
    ssh_key_endpoint = api_base + "/repositories/" + workspace + "/" + repository + "/pipelines_config/ssh/key_pair"

    # Prepare authentication string using provided credentials or environment variables
    auth = None
    if user != None and password != None:
        auth = user + ":" + password
    elif client_id != None and client_secret != None:
        fail("OAuth2 client credentials authentication is not supported in this Starlark translation")
    else:
        fail("Authentication requires either (user + password) or (client_id + client_secret)")

    # Helper to make HTTP requests using curl via ctx.run
    def http_request(method, url, body=None):
        curl_argv = ["curl", "-s", "-S", "-X", method, url, "-u", auth]
        if body != None:
            curl_argv.extend(["-H", "Content-Type: application/json", "-d", body])
        res = ctx.run(curl_argv, mutates=(method != "GET"))
        if res.skipped:
            return {"status": 200, "content": {}}, ""  # check_mode simulation
        if res.rc != 0:
            fail("HTTP request failed: " + res.stderr)
        # Parse JSON manually (simple keys only)
        # Assume response is small and flat for success cases
        out = res.stdout.strip()
        if out == "":
            return {"status": 204, "content": {}}, ""
        # Parse simple JSON like {"public_key": "...", "type": "..."}
        result = {}
        # Remove outer braces and split by comma
        inner = out.strip("{}")
        for part in inner.split(","):
            if ":" in part:
                k, v = part.strip().split(":", 1)
                k = k.strip().strip('"')
                v = v.strip().strip('"')
                result[k] = v
        return {"status": 200, "content": result}, ""

    # Get existing key pair
    info, _ = http_request("GET", ssh_key_endpoint)
    key_pair = info.get("content") if info.get("status") != 404 else None

    changed = False

    if state == "present":
        # Check if key exists and differs
        exists = key_pair != None
        needs_update = not exists or (key_pair.get("public_key") != public_key)

        if needs_update:
            if not ctx.check_mode:
                # Build JSON body manually without json module
                body = "{\"private_key\": \"" + private_key + "\", \"public_key\": \"" + public_key + "\"}"
                info, _ = http_request("PUT", ssh_key_endpoint, body)
                if info.get("status") != 200:
                    fail("Failed to create or update pipeline ssh key pair")
            changed = True

    elif state == "absent":
        if key_pair != None:
            if not ctx.check_mode:
                info, _ = http_request("DELETE", ssh_key_endpoint)
                if info.get("status") != 204:
                    fail("Failed to delete pipeline ssh key pair")
            changed = True

    if changed:
        msg = "updated" if state == "present" else "deleted"
    else:
        msg = "done"

    return {"changed": changed, "msg": msg}
