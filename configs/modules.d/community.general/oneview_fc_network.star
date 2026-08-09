def main(ctx, params):
    state = params["state"]
    data = params["data"]
    name = data.get("name")
    if name == None:
        fail("data.name is required")

    hostname = params.get("hostname")
    username = params.get("username")
    password = params.get("password")
    api_version = params.get("api_version")
    config_path = params.get("config")
    validate_etag = params.get("validate_etag", True)

    auth_header = ""
    if username != None and password != None:
        fail("oneview_fc_network requires base64 encoding for authentication; unsupported in Starlark runtime")

    if hostname == None:
        fail("hostname is required for oneview_fc_network")

    endpoint = "/rest/fc-networks"

    # Helper to call HTTP methods using curl (Starlark has no native HTTP client)
    def http(method, path, body=None):
        url = "https://" + hostname + path
        h = ["curl", "-k", "-s", "-X", method]
        h.extend(["-H", "Content-Type: application/json"])
        if auth_header != "":
            h.extend(["-H", "Authorization: " + auth_header])
        if api_version != None:
            h.extend(["-H", "Accept: application/json; api-version=" + str(api_version)])
        h.append(url)
        if body != None:
            # Write body to temp file and pass via @- or use echo
            fail("oneview_fc_network requires JSON body handling; not supported in Starlark runtime")

        res = ctx.run(h, mutates=True)
        if res.skipped:
            fail("would " + method.lower() + " " + url)
        if res.rc != 0:
            fail("HTTP " + method + " " + url + " failed: " + res.stderr)
        return res.stdout

    # Get current resource by name using filter
    def get_by_name(n):
        q = "filter=\"name = '" + n + "'\""
        res = http("GET", endpoint + "?" + q)
        # Parse JSON manually is unsafe; we must rely on jq or similar — not available
        fail("JSON parsing unsupported in Starlark runtime; oneview_fc_network cannot be implemented faithfully")

    resource = get_by_name(name)

    if state == "absent":
        if resource == None:
            return {"changed": False, "msg": "FC Network is already absent."}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete FC Network " + name}
        res_body = http("DELETE", endpoint + "/" + resource["uri"])
        # No way to parse response; assume success if no error
        return {"changed": True, "msg": "FC Network deleted successfully."}

    # state == "present"
    if resource != None:
        # In real implementation, compare full spec — omitted due to JSON parsing limitations
        fail("update logic requires JSON parsing; not supported in Starlark runtime")

    # Create new
    if ctx.check_mode:
        return {"changed": True, "msg": "would create FC Network " + name}
    fail("creation requires JSON body support; not implemented due to Starlark limitations")
