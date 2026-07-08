def main(ctx, params):
    client_id = params["client_id"]
    client_secret = params["client_secret"]
    topic = params["topic"]
    msg = params["msg"]

    # Build access token URL and payload
    token_url = "https://typetalk.com/oauth2/access_token"
    token_params = [
        "client_id=" + client_id,
        "client_secret=" + client_secret,
        "grant_type=client_credentials",
        "scope=topic.post"
    ]
    token_data = "&".join(token_params)
    token_headers = [
        "User-Agent: Ansible/typetalk module"
    ]

    # Request access token
    res = ctx.run(
        ["curl", "-s", "-X", "POST", "-d", token_data] + token_headers + [token_url],
        ok_codes=[200]
    )
    if res.rc != 0:
        fail("failed to obtain access token: " + res.stderr)

    token_json = res.stdout
    start = token_json.find('"access_token"')
    if start == -1:
        fail("access_token not found in token response")
    start = token_json.find(':', start)
    if start == -1:
        fail("malformed token response")
    start = token_json.find('"', start + 1)
    if start == -1:
        fail("malformed token response")
    end = token_json.find('"', start + 1)
    if end == -1:
        fail("malformed token response")
    access_token = token_json[start + 1:end]

    # Build message URL and payload
    post_url = "https://typetalk.com/api/v1/topics/" + str(topic)
    post_data = "message=" + msg
    post_headers = [
        "User-Agent: Ansible/typetalk module",
        "Authorization: Bearer " + access_token
    ]

    # Send message
    res = ctx.run(
        ["curl", "-s", "-X", "POST", "-d", post_data] + post_headers + [post_url],
        ok_codes=[200, 201]
    )
    if res.rc != 0:
        fail("failed to send message: " + res.stderr)

    return {"changed": True, "topic": topic, "msg": msg}
