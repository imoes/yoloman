def main(ctx, params):
    channel_token = params["channel_token"]
    message_content = params["message_content"]
    service = params.get("service", "ansible")
    url = params.get("url")
    icon_url = params.get("icon_url")
    validate_certs = params.get("validate_certs", True)

    # Build URL
    base_url = "https://grove.io/api/notice/"
    my_url = base_url + channel_token

    # Build POST data dict
    my_data = {"service": service, "message": message_content}
    if url != None:
        my_data["url"] = url
    if icon_url != None:
        my_data["icon_url"] = icon_url

    # Simple URL encoding (no special characters expected in typical usage)
    def urlencode(d):
        pairs = []
        for k in sorted(d.keys()):
            v = d[k]
            # Basic percent-encoding for space and plus
            v = v.replace("%", "%25").replace(" ", "%20").replace("+", "%2B")
            pairs.append(k + "=" + v)
        return "&".join(pairs)

    data = urlencode(my_data)

    # POST request using ctx.run with mutates=True (changes system state)
    headers = {
        "Content-Type": "application/x-www-form-urlencoded"
    }

    # Build curl command manually (no Python stdlib)
    argv = ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded"]
    if not validate_certs:
        argv.extend(["-k"])
    argv.extend(["-d", data, my_url])

    res = ctx.run(argv, mutates=True)
    if res.skipped:
        # Check mode: predict success
        return {"changed": True, "msg": "would send notification to Grove.io"}

    if res.rc != 0:
        fail("failed to send notification: " + res.stderr)

    # Grove.io API returns 200 OK on success (no body required to parse)
    return {"changed": True, "msg": "OK"}
