def main(ctx, params):
    app_token = params["app_token"]
    user_key = params["user_key"]
    msg = params["msg"]
    title = params.get("title")
    pri = params.get("pri", "0")
    device = params.get("device")

    # Validate priority
    if pri not in ["-2", "-1", "0", "1", "2"]:
        fail("invalid priority '%s', must be one of: -2, -1, 0, 1, 2" % pri)

    # Build request body
    data_parts = [
        "user=" + user_key,
        "token=" + app_token,
        "priority=" + pri,
        "message=" + msg
    ]
    if title != None:
        data_parts.append("title=" + title)
    if device != None:
        data_parts.append("device=" + device)

    body = "&".join(data_parts)

    # Perform POST request
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    res = ctx.run(
        ["curl", "-s", "-X", "POST", "-d", body, "-H", "Content-Type: application/x-www-form-urlencoded", "https://api.pushover.net/1/messages.json"],
        mutates=True
    )

    # Handle skipped (check_mode)
    if res.skipped:
        return {"changed": True, "msg": "would send Pushover notification"}

    # Check result
    if res.rc != 0:
        fail("failed to send Pushover notification: " + res.stderr)

    return {"changed": True, "msg": "message sent successfully"}
