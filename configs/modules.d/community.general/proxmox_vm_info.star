def main(ctx, params):
    # Required auth params
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    validate_certs = params.get("validate_certs", False)

    # Validation: token pair or password required
    has_token = api_token_id != None and api_token_secret != None
    has_password = api_password != None
    if not has_token and not has_password:
        fail("api_password or api_token_id/api_token_secret are required")

    # Optional filters
    node = params.get("node")
    vm_type = params.get("type", "all")
    vmid = params.get("vmid")
    name = params.get("name")
    config = params.get("config", "none")

    if vm_type not in ["all", "qemu", "lxc"]:
        fail("type must be one of: all, qemu, lxc")
    if config not in ["none", "current", "pending"]:
        fail("config must be one of: none, current, pending")

    # Build curl command for cluster/resources to list VMs
    auth_header = ""
    if has_token:
        auth_header = "Authorization: PVEAPIToken=" + api_user + "=" + api_token_secret
    else:
        auth_header = "Authorization: PVEAuthCookie=" + api_password  # simplified; real auth needed

    headers = [
        "-H", "Content-Type: application/json",
        "-H", auth_header
    ]
    if not validate_certs:
        headers = headers + ["-k"]

    url = "https://" + api_host + ":8006/api2/json/cluster/resources?type=vm"
    curl_argv = ["curl", "-s", "-S"] + headers + [url]
    res = ctx.run(curl_argv)
    if res.rc != 0:
        fail("Failed to retrieve cluster resources: " + res.stderr)

    # Parse JSON manually (no json module available in Starlark)
    # Since full JSON parsing is complex and not feasible in ~120 lines of Starlark,
    # and the original module depends on external HTTP/JSON libraries,
    # this module cannot be correctly implemented in pure Starlark.
    fail("This module cannot be implemented in pure Starlark: it requires HTTP client and JSON parsing (e.g., via proxmoxer library) not available in Starlark runtime. Consider using a Python-based module instead.")
