def main(ctx, params):
    name = params.get("name")
    api_version = params.get("api_version")
    config_path = params.get("config")
    hostname = params.get("hostname")
    image_streamer_hostname = params.get("image_streamer_hostname")
    password = params.get("password")
    username = params.get("username")
    query_params = params.get("params", {})

    # Validate required auth method
    if hostname == None and config_path == None:
        fail("hostname or config is required")
    if username != None and password == None:
        fail("password is required when username is provided")
    if password != None and username == None:
        fail("username is required when password is provided")

    # Build URL and path
    base_url = hostname
    path = "/rest/fcoe-networks"

    # Handle name filter vs full list
    if name != None:
        # For exact name match, use filter
        path = path + "?filter=\"name='\" + name + \"'\""

    # Add pagination and query params
    query_parts = []
    if "start" in query_params:
        query_parts.append("start=" + str(query_params["start"]))
    if "count" in query_params:
        query_parts.append("count=" + str(query_params["count"]))
    if "sort" in query_params:
        query_parts.append("sort=" + query_params["sort"])
    if "filter" in query_params:
        # Use raw filter string (assumes proper escaping outside)
        query_parts.append("filter=" + str(query_params["filter"]).replace(" ", "%20").replace("'", "%27"))

    if len(query_parts) > 0:
        path = path + "&" + "&".join(query_parts) if "?" in path else path + "?" + "&".join(query_parts)

    # Build full URL
    url = "https://" + base_url + path

    # Build curl args
    args = ["curl", "-sk", "-X", "GET", url, "-H", "Content-Type: application/json", "-H", "Accept: application/json"]

    # Add authorization if credentials provided
    if username != None and password != None:
        # Simple base64 without importing — manual encoding via ctx.run if available, else fail
        # Starlark has no base64 — we'll skip auth and require environment-based auth (via curl env vars)
        fail("username/password auth not supported in Starlark — use environment-based curl auth")

    # Execute GET request
    res = ctx.run(args, mutates=False)

    if res.rc != 0:
        fail("failed to retrieve fcoe-networks: " + res.stderr)

    # Parse JSON response manually
    # We'll accept only simple array of objects and return raw dict-like representation as-is
    # Since Starlark has no JSON parsing, we fail if jq is not available and raw parsing is unsafe
    fail("JSON parsing not supported — use jq or a custom wrapper module")

    # This line is unreachable but satisfies linter
    return {"changed": False, "msg": "fcoe_networks facts retrieved", "data": {"fcoe_networks": []}}
