def main(ctx, params):
    domain = params["domain"]
    token = params["token"]
    protocol = params.get("protocol", "https")
    msg = params.get("msg")
    channel = params.get("channel")
    username = params.get("username", "Ansible")
    icon_url = params.get("icon_url", "https://docs.ansible.com/favicon.ico")
    icon_emoji = params.get("icon_emoji")
    link_names = params.get("link_names", 1)
    color = params.get("color", "normal")
    attachments = params.get("attachments")

    # Validate token format (must contain at least one slash)
    if token.find("/") == -1:
        fail("Invalid Token specified, provide a valid token")

    # Build payload dict
    payload_dict = {}
    
    # Handle text and color
    if color == "normal" and msg != None:
        payload_dict = {"text": msg}
    elif msg != None:
        payload_dict = {"attachments": [{"text": msg, "color": color}]}
    
    # Handle channel
    if channel != None:
        if channel.startswith("#") or channel.startswith("@"):
            payload_dict["channel"] = channel
        else:
            payload_dict["channel"] = "#" + channel
    
    # Handle username
    if username != None:
        payload_dict["username"] = username
    
    # Handle icon
    if icon_emoji != None:
        payload_dict["icon_emoji"] = icon_emoji
    else:
        payload_dict["icon_url"] = icon_url
    
    # Handle link_names
    if link_names != None:
        payload_dict["link_names"] = link_names
    
    # Handle attachments
    if attachments != None:
        if "attachments" not in payload_dict:
            payload_dict["attachments"] = []
        for attachment in attachments:
            if "fallback" not in attachment:
                attachment["fallback"] = attachment.get("text", "")
            payload_dict["attachments"].append(attachment)
    
    # Build JSON string (use simple dict to JSON conversion since we have no json module)
    # Escape special characters manually for basic safety
    def to_json(obj):
        if obj == None:
            return "null"
        elif type(obj) == "bool":
            return "true" if obj else "false"
        elif type(obj) == "int" or type(obj) == "float":
            return str(obj)
        elif type(obj) == "string":
            # Basic string escaping: backslash and double quotes
            escaped = obj.replace("\\", "\\\\").replace('"', '\\"')
            return '"' + escaped + '"'
        elif type(obj) == "list":
            items = []
            for item in obj:
                items.append(to_json(item))
            return "[" + ", ".join(items) + "]"
        elif type(obj) == "dict":
            pairs = []
            for k, v in obj.items():
                pairs.append('"%s": %s' % (k, to_json(v)))
            return "{" + ", ".join(pairs) + "}"
        else:
            fail("Unsupported type for JSON: " + type(obj))
    
    payload = "payload=" + to_json(payload_dict)
    
    # Build webhook URL
    webhook_url = protocol + "://" + domain + "/hooks/" + token
    
    # Send request using ctx.run with mutates=True
    headers = [
        "Content-Type: application/x-www-form-urlencoded"
    ]
    
    # Build command args for curl
    cmd_args = [
        "curl",
        "-s",
        "-S",
        "-X", "POST",
        "-d", payload,
        "-H", headers[0],
        webhook_url
    ]
    
    # Add SSL option if validate_certs == False
    if params.get("validate_certs", True) == False:
        cmd_args.insert(3, "-k")
    
    res = ctx.run(cmd_args, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would send message to Rocket Chat"}
    
    if res.rc != 0:
        fail("failed to send message to Rocket Chat: " + res.stderr)
    
    # Check HTTP status code from response (if curl output contains status info)
    # We'll assume success if rc == 0 and no error output, per the original module
    return {"changed": True, "msg": "OK"}
