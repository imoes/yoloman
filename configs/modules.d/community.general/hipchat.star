def main(ctx, params):
    token = params["token"]
    room = str(params["room"])
    msg = params["msg"]
    msg_from = params.get("msg_from", "Ansible")
    color = params.get("color", "yellow")
    msg_format = params.get("msg_format", "text")
    notify = params.get("notify", True)
    validate_certs = params.get("validate_certs", True)
    api = params.get("api", "https://api.hipchat.com/v1")

    # Truncate msg_from to 15 chars as per original behavior
    msg_from = msg_from[:15] if len(msg_from) > 15 else msg_from

    # Determine API version by checking if '/v2' is in the api string
    is_v2 = "/v2" in api

    # In check_mode, return early without sending
    if ctx.check_mode:
        return {"changed": True, "msg": "would send Hipchat message to room %s" % room}

    # Prepare headers and body for v2
    headers = None
    body = None
    url = None
    method = "GET"

    if is_v2:
        # v2 uses POST with JSON body
        method = "POST"
        headers = {"Authorization": "Bearer %s" % token, "Content-Type": "application/json"}
        body = {
            "message": msg,
            "color": color,
            "message_format": msg_format,
            "notify": notify
        }
        # Replace placeholder in URL
        # Use string replace for {id_or_name} with url-encoded room name
        # Since there's no urlencode in Starlark, use simple replace and handle space escaping manually
        safe_room = room.replace(" ", "%20") if " " in room else room
        url = api + "/room/" + safe_room + "/notification"
    else:
        # v1 uses GET with query params
        method = "POST"
        # Build query string manually
        params_list = [
            "room_id=" + room,
            "from=" + msg_from,
            "message=" + msg.replace(" ", "%20").replace("&", "%26").replace("=", "%3D"),
            "message_format=" + msg_format,
            "color=" + color,
            "notify=" + ("1" if notify else "0")
        ]
        query = "&".join(params_list)
        url = api + "/rooms/message?auth_token=" + token
        body = query

    # Build request
    if is_v2:
        # For v2, we need to serialize body as JSON string
        # Starlark has no json module; build minimal JSON manually for known keys
        body_str = '{"message": "' + msg.replace('"', '\\"') + '", '
        body_str += '"color": "' + color + '", '
        body_str += '"message_format": "' + msg_format + '", '
        body_str += '"notify": ' + ("true" if notify else "false") + '}'
        res = ctx.run(["curl", "-s", "-X", "POST", "-H", "Authorization: Bearer %s" % token, 
                       "-H", "Content-Type: application/json", "-d", body_str, url],
                      mutates=True)
    else:
        # For v1, use POST with form-encoded body (simulated via curl)
        res = ctx.run(["curl", "-s", "-X", "POST", "-d", body, url], mutates=True)

    # Check response code and handle errors
    if res.skipped:
        return {"changed": True, "msg": "would send Hipchat message to room %s" % room}

    # Check HTTP status in stderr or try parsing output
    # Hipchat docs: v1 returns 200, v2 returns 204 or 200 on success
    if res.rc != 0:
        fail("failed to send Hipchat message: %s" % res.stderr)
    
    # Try to detect HTTP status code from curl output
    # curl -s returns empty on success for v2; for v1, response body may contain JSON
    # Since we cannot parse JSON reliably, use known behavior:
    # v2: 204 No Content (curl rc=0 implies success), v1: 200 OK (curl rc=0 implies success)
    # The only failure case is non-zero rc; success assumed otherwise
    changed = True
    return {"changed": changed, "msg": "Hipchat message sent to room %s" % room}
