def main(ctx, params):
    # Connection parameters with fallback to env vars
    url = params.get("api_url")
    username = params.get("api_username")
    password = params.get("api_password")

    if url == None:
        url = ctx.facts().get("env_ONE_URL", "")
    if username == None:
        username = ctx.facts().get("env_ONE_USERNAME", "")
    if password == None:
        password = ctx.facts().get("env_ONE_PASSWORD", "")

    if url == "" or username == "" or password == "":
        fail("One or more connection parameters (api_url, api_username, api_password) were not specified")

    ids = params.get("ids")
    name = params.get("name")

    if ids != None and name != None:
        fail("parameters are mutually exclusive: ids, name")

    # Since Starlark cannot make HTTP requests, fail with clear message.
    # In real Starlark deployment, this would be replaced with ctx.http_* or similar.
    fail("one_image_info requires HTTP client (pyone) which is not available in Starlark runtime. Use original Ansible module.")

    # The following is unreachable but present for syntactic correctness.
    # It would contain the full logic if HTTP were available.
    return {"changed": False, "msg": "no images retrieved (stub)", "images": []}
