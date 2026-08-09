def main(ctx, params):
    token = params["token"]
    environment = params["environment"]
    revision = params["revision"]
    user = params.get("user")
    rollbar_user = params.get("rollbar_user")
    comment = params.get("comment")
    url = params.get("url", "https://api.rollbar.com/api/1/deploy/")
    validate_certs = params.get("validate_certs", True)

    # Build POST data string manually (no json/urlencode modules)
    data_parts = [
        "access_token=" + token,
        "environment=" + environment,
        "revision=" + revision
    ]
    if user != None:
        data_parts.append("local_username=" + user)
    if rollbar_user != None:
        data_parts.append("rollbar_username=" + rollbar_user)
    if comment != None:
        data_parts.append("comment=" + comment)
    data = "&".join(data_parts)

    # Check mode: predict change without sending
    if ctx.check_mode:
        return {"changed": True, "msg": "would notify Rollbar of deployment"}

    # Prepare headers
    headers = ["Content-Type: application/x-www-form-urlencoded"]

    # Send POST request via curl
    curl_cmd = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}"]
    if not validate_certs:
        curl_cmd.extend(["-k"])
    curl_cmd.extend(["-X", "POST", "-d", data, url])

    res = ctx.run(curl_cmd)
    if res.rc != 0:
        fail("failed to notify Rollbar: " + res.stderr)

    # Parse HTTP status code (curl -w outputs to stdout)
    status = res.stdout.strip()
    if status == "200":
        return {"changed": True, "msg": "successfully notified Rollbar"}
    fail("HTTP result code: " + status + " connecting to " + url)
