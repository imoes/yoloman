def main(ctx, params):
    url = params["url"]
    api_key = params["api_key"]
    text = params.get("text")
    attachments = params.get("attachments")
    channel = params.get("channel")
    username = params.get("username", "Ansible")
    icon_url = params.get("icon_url", "https://docs.ansible.com/favicon.ico")
    validate_certs = params.get("validate_certs", True)

    # require one of text or attachments
    if text == None and attachments == None:
        fail("one of 'text' or 'attachments' is required")

    webhook_url = url + "/hooks/" + api_key

    # build payload dict
    payload = {}
    for key in ["text", "channel", "username", "icon_url", "attachments"]:
        val = params.get(key)
        if val != None:
            payload[key] = val

    # convert payload to JSON manually (no json module)
    def to_json(obj):
        if type(obj) == "string":
            s = obj
            # escape common JSON special chars
            s = s.replace("\\", "\\\\")
            s = s.replace('"', '\\"')
            s = s.replace("\n", "\\n")
            s = s.replace("\r", "\\r")
            s = s.replace("\t", "\\t")
            return '"' + s + '"'
        elif type(obj) == "bool":
            return "true" if obj else "false"
        elif type(obj) == "int" or type(obj) == "float":
            return str(obj)
        elif type(obj) == "NoneType":
            return "null"
        elif type(obj) == "list":
            items = []
            for item in obj:
                items.append(to_json(item))
            return "[" + ", ".join(items) + "]"
        elif type(obj) == "dict":
            pairs = []
            for k in sorted(obj.keys()):
                pairs.append(to_json(k) + ": " + to_json(obj[k]))
            return "{" + ", ".join(pairs) + "}"
        else:
            fail("unsupported type in payload: " + str(type(obj)))

    payload_str = to_json(payload)

    # prepare headers
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json"
    }

    # build body for ctx.run (no quotes around headers)
    body = payload_str

    # prepare HTTP headers as list of "Key: Value" strings
    header_list = []
    for k in headers:
        header_list.append(k + ": " + headers[k])

    # In check_mode, just report success without sending
    if ctx.check_mode:
        return {
            "changed": False,
            "msg": "OK",
            "payload": payload_str,
            "webhook_url": webhook_url
        }

    # send POST request
    res = ctx.run(
        ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-H", "Accept: application/json", "-d", body, webhook_url],
        mutates=True
    )

    # handle failure
    if res.rc != 0:
        err_msg = res.stderr.strip() if res.stderr != "" else "unknown error"
        fail("failed to send mattermost message: " + err_msg)

    # response was sent successfully
    return {
        "changed": False,
        "msg": "OK",
        "payload": payload_str,
        "webhook_url": webhook_url
    }
