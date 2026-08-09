def main(ctx, params):
    recipient_type = params["recipient_type"]
    recipient_id = params["recipient_id"]
    msg = params["msg"]
    personal_token = params["personal_token"]
    msg_type = params.get("msg_type", "text")

    if recipient_type not in ("roomId", "toPersonEmail", "toPersonId"):
        fail("recipient_type must be one of: roomId, toPersonEmail, toPersonId")
    if msg_type not in ("text", "markdown"):
        fail("msg_type must be one of: text, markdown")

    if ctx.check_mode:
        url = "https://webexapis.com/v1/people/me"
        mutates = False
        cmd = [
            "curl",
            "-s",
            "-o", "/dev/null",
            "-w", "%{http_code}",
            "-X", "GET",
            "-H", "Authorization: Bearer " + personal_token,
            url,
        ]
    else:
        url = "https://webexapis.com/v1/messages"
        payload_dict = {
            recipient_type: recipient_id,
            msg_type: msg,
        }
        payload = str(payload_dict).replace("'", '"')
        mutates = True
        cmd = [
            "curl",
            "-s",
            "-o", "/dev/null",
            "-w", "%{http_code}",
            "-X", "POST",
            "-H", "Authorization: Bearer " + personal_token,
            "-H", "content-type: application/json",
            "-d", payload,
            url,
        ]

    res = ctx.run(cmd, mutates=mutates)
    if res.skipped:
        return {"changed": True, "msg": "would authenticate with Webex" if ctx.check_mode else "would send message to Webex"}

    status_code = int(res.stdout.strip())
    if status_code != 200:
        fail("Webex API request failed with status " + str(status_code))

    if ctx.check_mode:
        return {"changed": False, "msg": "Authentication Successful."}
    else:
        return {"changed": True, "msg": "Message sent successfully."}
