def main(ctx, params):
    auth_url = params["auth_url"]
    login_user = params["login_user"]
    login_password = params["login_password"]
    command_options = params.get("command_options", "cmms")
    uuid = params.get("uuid")
    chassis = params.get("chassis")

    # Validate required options
    if command_options == "cmms_by_uuid" and uuid == None:
        fail("UUID of device is required for cmms_by_uuid command.")
    if command_options == "cmms_by_chassis_uuid" and chassis == None:
        fail("UUID of chassis is required for cmms_by_chassis_uuid command.")

    # Prepare HTTP headers for basic auth
    creds = login_user + ":" + login_password
    # Manual base64 encoding table for ASCII
    b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    def b64_encode(s):
        result = []
        i = 0
        while i < len(s):
            c1 = ord(s[i])
            i += 1
            c2 = ord(s[i]) if i < len(s) else 0
            i += 1
            c3 = ord(s[i]) if i < len(s) else 0
            i += 1

            result.append(b64_chars[(c1 >> 2) & 0x3F])
            result.append(b64_chars[((c1 & 3) << 4) | ((c2 >> 4) & 0xF)])
            result.append(b64_chars[((c2 & 0xF) << 2) | ((c3 >> 6) & 0x3)] if i - 1 < len(s) else "=")
            result.append("=" if i - 2 >= len(s) else b64_chars[c3 & 0x3F])
        return "".join(result)

    auth_header = "Basic " + b64_encode(creds)

    # Build URL
    if command_options == "cmms":
        url = auth_url + "/v1/Inventory/CMMS"
    elif command_options == "cmms_by_uuid":
        url = auth_url + "/v1/Inventory/CMMS/" + uuid
    elif command_options == "cmms_by_chassis_uuid":
        url = auth_url + "/v1/Inventory/CMMS?ChassisUUID=" + chassis
    else:
        fail("Unsupported command_options: " + command_options)

    # Make the HTTP request
    res = ctx.run(
        ["curl", "-s", "-k", "-X", "GET", url, "-H", "Authorization: " + auth_header, "-H", "Content-Type: application/json"],
        mutates=False,
    )

    if res.rc != 0:
        fail("Failed to fetch CMMS data: " + res.stderr)

    # Parse JSON manually (no json module)
    content = res.stdout.strip()
    if content == "":
        fail("Empty response from server")

    # Basic validation: check for obvious JSON structure
    if not (content.startswith("{") or content.startswith("[")):
        fail("Unexpected non-JSON response")

    return {
        "changed": False,
        "msg": "Success " + command_options + " result",
        "data": {"result": content},
    }
