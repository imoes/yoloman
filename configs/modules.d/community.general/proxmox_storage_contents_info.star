def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    storage = params["storage"]
    node = params["node"]
    content = params.get("content", "all")
    vmid = params.get("vmid")
    validate_certs = params.get("validate_certs", False)

    # Validate authentication method
    if api_password == None and api_token_id == None:
        fail("One of api_password or api_token_id is required")
    if api_token_id != None and api_token_secret == None:
        fail("api_token_secret is required when using api_token_id")
    if api_token_id == None and api_token_secret != None:
        fail("api_token_id is required when using api_token_secret")

    # Build authentication headers
    auth_headers = []
    if api_password != None:
        auth_headers = ["-u", api_user + "@" + node, "-k", api_password]
    else:
        auth_headers = ["-u", api_user, "-T", api_token_id + "=" + api_token_secret]

    # Build curl command
    url = "https://%s:8006/api2/json/nodes/%s/storage/%s/content" % (api_host, node, storage)
    if content != "all":
        url += "?content=" + content
    if vmid != None:
        url += "&vmid=" + str(vmid)

    curl_args = ["curl", "-s", "-k"]
    if not validate_certs:
        curl_args += ["-k"]
    curl_args += auth_headers + [url]

    res = ctx.run(curl_args)
    if res.rc != 0:
        fail("Failed to fetch storage content: " + res.stderr)

    # Parse JSON manually (no json module)
    # Basic JSON parser for simple object list
    output = res.stdout.strip()
    if not output:
        fail("Empty response from Proxmox API")
    # Remove outer brackets if present
    if output.startswith("[") and output.endswith("]"):
        output = output[1:-1]
    if not output:
        return {"changed": False, "proxmox_storage_content": []}

    # Split entries
    entries = []
    depth = 0
    current = ""
    i = 0
    while i < len(output):
        c = output[i]
        if c == '{':
            depth += 1
            current += c
        elif c == '}':
            depth -= 1
            current += c
            if depth == 0:
                entries.append(current.strip())
                current = ""
        elif depth > 0:
            current += c
        i += 1

    # Parse each entry
    parsed_entries = []
    for entry in entries:
        if not entry:
            continue
        parsed_entry = {}
        # Remove braces
        entry = entry.strip()[1:-1]
        # Split by commas, but avoid commas inside quotes
        parts = []
        current_part = ""
        in_quotes = False
        i = 0
        while i < len(entry):
            c = entry[i]
            if c == '"':
                in_quotes = not in_quotes
            elif c == ',' and not in_quotes:
                parts.append(current_part.strip())
                current_part = ""
                i += 1
                continue
            current_part += c
            i += 1
        if current_part.strip():
            parts.append(current_part.strip())

        # Parse key-value pairs
        for part in parts:
            if ':' not in part:
                continue
            # Split at first colon
            colon_pos = part.find(':')
            key = part[:colon_pos].strip().strip('"')
            value = part[colon_pos+1:].strip()

            # Remove quotes from value if present
            if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            # Try convert to int
            elif (value.isdigit() or (value.startswith('-') and len(value) > 1 and value[1:].isdigit())):
                value = int(value)

            parsed_entry[key] = value

        if parsed_entry:
            parsed_entries.append(parsed_entry)

    return {"changed": False, "proxmox_storage_content": parsed_entries}
