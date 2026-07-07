def main(ctx, params):
    # Extract parameters
    token = params["token"]
    msg = params["msg"]
    type_ = params["type"]
    validate_certs = params.get("validate_certs", True)
    
    # Build URL based on type
    if type_ == "inbox":
        url = "https://api.flowdock.com/v1/messages/team_inbox/" + token
    elif type_ == "chat":
        url = "https://api.flowdock.com/v1/messages/chat/" + token
    else:
        fail("unsupported type: " + type_)
    
    # Build payload
    payload = {}
    payload["content"] = msg
    
    # Required params for chat
    if type_ == "chat":
        external_user_name = params.get("external_user_name")
        if external_user_name == None:
            fail("external_user_name is required for the 'chat' type")
        payload["external_user_name"] = external_user_name
    
    # Required params for inbox
    if type_ == "inbox":
        required_inbox = ["from_address", "source", "subject"]
        for key in required_inbox:
            val = params.get(key)
            if val == None:
                fail(key + " is required for the 'inbox' type")
            payload[key] = val
    
    # Validate incompatible options
    if type_ == "inbox":
        if params.get("external_user_name") != None:
            fail("external_user_name is not valid for the 'inbox' type")
    elif type_ == "chat":
        chat_incompatible = ["from_address", "source", "subject"]
        for key in chat_incompatible:
            if params.get(key) != None:
                fail(key + " is not valid for the 'chat' type")
    
    # Optional params
    tags = params.get("tags")
    if tags != None:
        payload["tags"] = tags
    
    if type_ == "inbox":
        optional_inbox = ["from_name", "reply_to", "project", "link"]
        for key in optional_inbox:
            val = params.get(key)
            if val != None:
                payload[key] = val
    
    if type_ == "chat":
        chat_incompatible = ["from_name", "reply_to", "project", "link"]
        for key in chat_incompatible:
            if params.get(key) != None:
                fail(key + " is not valid for the 'chat' type")
    
    # Check mode
    if ctx.check_mode:
        return {"changed": True, "msg": "would send message to flowdock"}
    
    # Build query string manually (urlencode equivalent)
    def urlencode(params_dict):
        items = []
        for k, v in params_dict.items():
            items.append(k + "=" + v)
        return "&".join(items)
    
    data = urlencode(payload)
    
    # Execute HTTP POST request
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json"
    }
    
    # Note: ctx.run() doesn't support custom headers directly in this Starlark runtime.
    # In real implementation, we'd need an HTTP helper, but for this translation we'll
    # assume a hypothetical http_post method exists in ctx, or use a workaround with curl.
    # Since the original implementation used fetch_url, we simulate it using curl.
    
    # Construct curl command
    curl_args = [
        "curl", "-s", "-X", "POST",
        "-H", "Content-Type: application/x-www-form-urlencoded",
        "-H", "Accept: application/json"
    ]
    
    if not validate_certs:
        curl_args.append("-k")
    
    curl_args.extend(["-d", data, url])
    
    res = ctx.run(curl_args, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would send message to flowdock"}
    
    # Check for success (status 200)
    if res.rc != 0:
        fail("unable to send msg: " + res.stderr)
    
    # If we got here, we succeeded
    return {"changed": True, "msg": msg}
