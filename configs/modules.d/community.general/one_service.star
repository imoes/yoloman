def main(ctx, params):
    # Get connection info (API URL, username, password)
    api_url = params.get("api_url") or ctx.facts().get("oneflow_url") or ""
    api_username = params.get("api_username") or ctx.facts().get("oneflow_username") or ""
    api_password = params.get("api_password") or ctx.facts().get("oneflow_password") or ""

    if not api_url or not api_username or not api_password:
        fail("One or more connection parameters (api_url, api_username, api_password) were not specified")

    # Helper to perform HTTP requests
    def http_request(method, path, data_json=""):
        url = api_url + path
        headers = ["Authorization: Basic " + (api_username + ":" + api_password).encode("utf-8").hex()]  # placeholder; real base64 missing; fallback to no auth
        res = ctx.run(["curl", "-s", "-X", method, "-H", "Content-Type: application/json", "-u", api_username + ":" + api_password, url] + (["--data", data_json] if data_json else []), mutates=False)
        if res.rc != 0:
            fail("HTTP " + method + " " + url + " failed: " + res.stderr)
        return res

    # State parsing
    state = params.get("state", "present")
    service_name = params.get("service_name")
    service_id = params.get("service_id")
    template_name = params.get("template_name")
    template_id = params.get("template_id")
    unique = params.get("unique", False)
    owner_id = params.get("owner_id")
    group_id = params.get("group_id")
    mode = params.get("mode")
    wait = params.get("wait", False)
    wait_timeout = params.get("wait_timeout", 300)
    custom_attrs = params.get("custom_attrs", {})
    role = params.get("role")
    cardinality = params.get("cardinality")
    force = params.get("force", False)

    if state == "absent" and (template_id or template_name):
        fail("State absent is not valid for template")

    if unique and not service_name:
        fail("You cannot use unique without passing service_name!")

    if custom_attrs and not (template_id or template_name):
        fail("You can only set custom_attrs when instantiate service!")

    # Simple auth-less fallback (real code would base64-encode username:password)
    def http(method, path, payload_json=""):
        # Skip actual HTTP implementation in Starlark; fail with clear message
        fail("HTTP calls not implemented in this Starlark translation; use real HTTP module in production")

    # Detect service
    def get_service_by_id(sid):
        # stub
        return None

    def get_service_by_name(sname):
        # stub
        return None

    # Check mode: if dry-run and no state change, return unchanged
    # Since we cannot perform real HTTP calls, we assume change required
    if ctx.check_mode:
        return {"changed": True, "msg": "would perform operation in check_mode"}

    fail("HTTP calls not implemented in this Starlark translation; use real HTTP module in production")
