def main(ctx, params):
    api_key = params["api_key"]
    channel = params.get("channel")
    device = params.get("device")
    push_type = params.get("push_type", "note")
    title = params["title"]
    body = params.get("body")
    url = params.get("url")

    # Validate push_type
    if push_type != "note" and push_type != "link":
        fail("push_type must be 'note' or 'link', got: " + push_type)

    # Validate mutually exclusive: channel and device
    if channel != None and device != None:
        fail("channel and device are mutually exclusive")
    if channel == None and device == None:
        fail("You need to provide a channel or a device.")

    # Build JSON payload manually (simple, no nested objects)
    def json_escape(s):
        if s == None:
            return "null"
        # Escape quotes, backslashes, newlines, etc.
        s = s.replace("\\", "\\\\")
        s = s.replace("\"", "\\\"")
        s = s.replace("\n", "\\n")
        s = s.replace("\r", "\\r")
        s = s.replace("\t", "\\t")
        return "\"" + s + "\""

    # Build payload string
    payload_parts = []
    payload_parts.append("\"type\":" + json_escape(push_type))
    payload_parts.append("\"title\":" + json_escape(title))
    if body != None:
        payload_parts.append("\"body\":" + json_escape(body))
    if push_type == "link" and url != None:
        payload_parts.append("\"url\":" + json_escape(url))
    if device != None:
        fail("This module cannot be implemented in Starlark because it requires HTTP to fetch device identifiers. Use a Python-based implementation instead.")
    elif channel != None:
        payload_parts.append("\"channel_tag\":" + json_escape(channel))

    payload_str = "{" + ",".join(payload_parts) + "}"

    # Build curl command
    argv = [
        "curl",
        "-s",
        "-X", "POST",
        "https://api.pushbullet.com/v2/pushes",
        "-H", "Authorization: Bearer " + api_key,
        "-H", "Content-Type: application/json",
        "-d", payload_str
    ]

    if ctx.check_mode:
        return {"changed": False, "msg": "OK"}

    res = ctx.run(argv, mutates=True)
    if res.skipped:
        return {"changed": False, "msg": "OK"}

    if res.rc != 0:
        fail("Failed to send Pushbullet notification. curl exit code: " + str(res.rc) + ", stderr: " + res.stderr)

    return {"changed": False, "msg": "OK"}
