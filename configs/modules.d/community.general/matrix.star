def main(ctx, params):
    hs_url = params["hs_url"]
    msg_html = params["msg_html"]
    msg_plain = params["msg_plain"]
    room_id = params["room_id"]
    token = params.get("token")
    user_id = params.get("user_id")
    password = params.get("password")

    # Check mutually exclusive and required_one_of manually
    if token != None and password != None:
        fail(" mutually_exclusive: password and token")
    if token == None and password == None:
        fail("required_one_of: password or token")
    if password != None and user_id == None:
        fail("required_together: user_id when password is provided")

    # In check_mode, we can only validate arguments and simulate — no actual API calls
    if ctx.check_mode:
        return {"changed": True, "msg": "would send matrix notification"}

    # Note: Starlark has no matrix-client library — this module cannot perform real Matrix API calls.
    # Since ctx has no built-in HTTP client, and we cannot import external libraries,
    # we must fail with a clear message indicating the runtime limitation.
    fail("module 'matrix' is not supported in Starlark runtime: no HTTP client available for Matrix CS-API")
