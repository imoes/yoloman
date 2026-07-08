def main(ctx, params):
    token = params["token"]
    api_method = params.get("api_method", "SendMessage")
    api_args = params.get("api_args") or {}

    # Build URL
    url = "https://api.telegram.org/bot{token}/{api_method}".format(token=token, api_method=api_method)

    # Check mode: predict without sending
    if ctx.check_mode:
        return {"changed": True, "msg": "would send message via telegram"}

    # Prepare POST body
    # Convert api_args dict to JSON manually (Starlark has no json module)
    def to_json(obj):
        if type(obj) == "NoneType":
            return "null"
        elif type(obj) == "bool":
            return "true" if obj else "false"
        elif type(obj) == "int" or type(obj) == "float":
            return str(obj)
        elif type(obj) == "string":
            # Simple escaping for double quotes and backslashes
            escaped = obj.replace("\\", "\\\\").replace('"', '\\"')
            return '"' + escaped + '"'
        elif type(obj) == "list":
            items = []
            for i in range(len(obj)):
                items.append(to_json(obj[i]))
            return "[" + ", ".join(items) + "]"
        elif type(obj) == "dict":
            pairs = []
            for k in sorted(obj.keys()):
                pairs.append('"' + k.replace("\\", "\\\\").replace('"', '\\"') + '": ' + to_json(obj[k]))
            return "{" + ", ".join(pairs) + "}"
        else:
            fail("Unsupported type for JSON: " + type(obj))

    body = to_json(api_args)

    # Send request
    res = ctx.run(
        ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-d", body, url],
        mutates=True
    )

    # Interpret result
    if res.rc == 0:
        return {"changed": True, "msg": "message sent"}
    else:
        # Parse error response if possible
        stderr = res.stderr.strip()
        err_msg = "curl failed with rc={rc}".format(rc=res.rc)
        if stderr != "":
            err_msg = err_msg + ": " + stderr

        # Try to extract error description from body (if curl returned a JSON)
        # Since curl doesn't provide the response body via rc/stdout/stderr in a standard way,
        # and Starlark ctx.run only captures stdout/stderr, we can't reliably parse JSON body.
        # However, we can attempt to detect common patterns in stderr or stdout.
        fail("Failed to send message: " + err_msg)
