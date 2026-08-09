def _extract_token(response):
    token_start = response.find("<token>")
    if token_start >= 0:
        token_end = response.find("</token>", token_start)
        if token_end >= 0:
            return response[token_start + 7:token_end].strip()
    return ""

def main(ctx, params):
    host = params.get("host", "127.0.0.1")
    port = params.get("port")
    username = params.get("username", "cobbler")
    password = params.get("password")
    use_ssl = params.get("use_ssl", True)
    validate_certs = params.get("validate_certs", True)

    proto = "https" if use_ssl else "http"
    if port == None:
        port = 443 if use_ssl else 80
    else:
        port = int(port)

    url = "{proto}://{host}:{port}/cobbler_api".format(proto=proto, host=host, port=port)

    # Build curl command for login
    curl_headers = [
        "-s", "-X", "POST",
        "-d", "method=login",
        "-d", "username=" + username,
        "-d", "password=" + password,
    ]

    if not validate_certs:
        curl_headers.append("-k")

    curl_headers.append(url)

    res = ctx.run(["curl"] + curl_headers, mutates=False)
    if res.rc != 0:
        fail("Failed to log in to Cobbler at " + url + ": " + res.stderr)
    
    token = _extract_token(res.stdout)
    if not token:
        fail("Login failed: no token returned from Cobbler")

    if ctx.check_mode:
        return {"changed": True, "msg": "would sync Cobbler at " + url}

    # Perform sync
    sync_cmd = [
        "curl", "-s", "-X", "POST",
        "-d", "method=sync",
        "-d", "token=" + token,
    ]
    if not validate_certs:
        sync_cmd.append("-k")
    sync_cmd.append(url)

    sync_res = ctx.run(sync_cmd, mutates=True)
    if sync_res.rc != 0:
        fail("Failed to sync Cobbler at " + url + ": " + sync_res.stderr)

    return {"changed": True, "msg": "Cobbler synced successfully"}
