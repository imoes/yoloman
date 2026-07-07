def main(ctx, params):
    webhook_id = params["webhook_id"]
    webhook_token = params["webhook_token"]
    content = params.get("content")
    embeds = params.get("embeds")
    username = params.get("username")
    avatar_url = params.get("avatar_url")
    tts = params.get("tts", False)

    # Validate required_one_of: at least one of content or embeds must be provided
    if content == None and embeds == None:
        fail("One of 'content' or 'embeds' must be specified")

    # Build payload dict
    payload = {
        "content": content,
        "username": username,
        "avatar_url": avatar_url,
        "tts": tts,
        "embeds": embeds,
    }

    # Filter out None values for cleaner JSON (optional but matches original behavior)
    payload = {k: v for k, v in payload.items() if v != None}

    # Build URL
    url = "https://discord.com/api/webhooks/" + webhook_id + "/" + webhook_token

    # In check_mode, perform a read-only GET to validate webhook existence
    if ctx.check_mode:
        headers = ["Content-Type: application/json"]
        res = ctx.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "GET", url] + headers, mutates=False)
        if res.rc != 0:
            fail("Failed to validate webhook: curl exited with rc=" + str(res.rc))
        # Parse http_code from stdout
        http_code = int(res.stdout.strip()) if res.stdout.strip().isdigit() else 0
        if http_code != 200:
            fail("Webhook validation failed with http_code=" + str(http_code))
        return {"changed": False, "msg": "Webhook is valid", "http_code": http_code}

    # Non-check_mode: POST the message
    # Since Starlark has no JSON serialization, we build a minimal JSON manually
    # But ctx.run accepts raw bytes via stdin; however, the ctx API only provides
    # file_write and run. We simulate payload by writing to a temp file and passing via --data-binary
    # However, ctx.run() cannot do stdin piping. So we build JSON string directly.

    # Build JSON payload manually (simple escaping)
    def json_str(s):
        if s == None:
            return "null"
        if isinstance(s, bool):
            return "true" if s else "false"
        if isinstance(s, int):
            return str(s)
        if isinstance(s, str):
            return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'
        if isinstance(s, list):
            items = ", ".join([json_str(x) for x in s])
            return "[" + items + "]"
        if isinstance(s, dict):
            pairs = ", ".join([json_str(k) + ": " + json_str(v) for k, v in s.items()])
            return "{" + pairs + "}"
        return "null"

    payload_json = json_str(payload)

    # Prepare curl command
    headers = ["-H", "Content-Type: application/json"]
    data = ["-d", payload_json]
    command = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", url] + headers + data

    res = ctx.run(command, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would send Discord message", "http_code": 204}

    if res.rc != 0:
        fail("Failed to send Discord message: curl exited with rc=" + str(res.rc) + ", stderr=" + res.stderr)

    # Parse http_code
    http_code = int(res.stdout.strip()) if res.stdout.strip().isdigit() else 0

    if http_code != 204:
        fail("Discord API returned http_code=" + str(http_code) + ", expected 204")

    return {"changed": True, "msg": "Discord message sent successfully", "http_code": http_code}
