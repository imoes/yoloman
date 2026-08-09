def main(ctx, params):
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    region = params["region"]
    server_id = params["server_id"]
    user_data = params.get("user_data") or {}
    validate_certs = params.get("validate_certs", True)
    timeout = params.get("api_timeout", 30)

    # Map region to API endpoint (simplified mapping for supported regions)
    region_map = {
        "ams1": "https://api.scaleway.com/instance/v1/zones/ams1",
        "EMEA-NL-EVS": "https://api.scaleway.com/instance/v1/zones/ams1",
        "par1": "https://api.scaleway.com/instance/v1/zones/par1",
        "EMEA-FR-PAR1": "https://api.scaleway.com/instance/v1/zones/par1",
        "par2": "https://api.scaleway.com/instance/v1/zones/par2",
        "EMEA-FR-PAR2": "https://api.scaleway.com/instance/v1/zones/par2",
        "waw1": "https://api.scaleway.com/instance/v1/zones/waw1",
        "EMEA-PL-WAW1": "https://api.scaleway.com/instance/v1/zones/waw1",
    }
    base_url = region_map.get(region)
    if base_url == None:
        fail("unsupported region: " + region)

    headers = {
        "Authorization": "Bearer " + api_token,
        "Content-Type": "application/json",
    }

    # Fetch current user_data keys list
    list_path = base_url + "/servers/" + server_id + "/user_data"
    res = ctx.run(
        ["curl", "-sS", "-X", "GET", "-H", "Authorization: Bearer " + api_token, list_path],
        mutates=False,
    )
    if res.rc != 0:
        fail("failed to fetch user_data list: " + res.stderr)
    if res.stdout == None or res.stdout == "":
        fail("empty response body for user_data list")
    parsed = res.stdout

    # Extract keys using string search
    keys_str = ""
    if '"user_data"' in parsed:
        start_idx = parsed.find('"user_data"') + len('"user_data"')
        if start_idx > len('"user_data"'):
            while start_idx < len(parsed) and parsed[start_idx] in " \t\n:":
                start_idx += 1
            if start_idx < len(parsed) and parsed[start_idx] == "[":
                end_idx = parsed.find("]", start_idx)
                if end_idx != -1:
                    keys_str = parsed[start_idx+1:end_idx]
    present_keys = []
    if keys_str != "":
        for part in keys_str.split(","):
            part = part.strip().strip('"')
            if part != "":
                present_keys.append(part)

    present_user_data = {}
    for key in present_keys:
        key_path = base_url + "/servers/" + server_id + "/user_data/" + key
        res = ctx.run(
            ["curl", "-sS", "-X", "GET", "-H", "Authorization: Bearer " + api_token, key_path],
            mutates=False,
        )
        if res.rc != 0:
            fail("failed to fetch user_data " + key + ": " + res.stderr)
        present_user_data[key] = res.stdout.rstrip("\n")

    # Convert user_data dict values to strings (cloud-init is a string)
    desired_user_data = {}
    for k, v in user_data.items():
        desired_user_data[k] = str(v) if v != None else ""

    # Idempotency check
    if present_user_data == desired_user_data:
        return {"changed": False, "msg": "user_data already matches desired state"}

    # Build list of operations
    to_delete = [k for k in present_user_data if k not in desired_user_data]
    to_update = []
    for k, v in desired_user_data.items():
        if k not in present_user_data or present_user_data[k] != v:
            to_update.append((k, v))

    if ctx.check_mode:
        changed = (len(to_delete) > 0) or (len(to_update) > 0)
        msg = "would update user_data for server " + server_id
        if changed:
            msg += ": delete " + str(to_delete) + ", update " + str(to_update)
        return {"changed": changed, "msg": msg}

    # Delete keys first
    for key in to_delete:
        del_path = base_url + "/servers/" + server_id + "/user_data/" + key
        res = ctx.run(
            ["curl", "-sS", "-X", "DELETE", "-H", "Authorization: Bearer " + api_token, del_path],
            mutates=True,
        )
        if res.rc != 0:
            fail("failed to delete user_data " + key + ": " + res.stderr)

    # Update keys
    for key, value in to_update:
        put_path = base_url + "/servers/" + server_id + "/user_data/" + key
        tmp_res = ctx.run(["mktemp"], mutates=False)
        if tmp_res.rc != 0:
            fail("failed to create temp file")
        tmp_path = tmp_res.stdout.strip()
        ctx.file_write(tmp_path, value)
        res = ctx.run(
            ["curl", "-sS", "-X", "PATCH", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: text/plain", "--data-binary", "@" + tmp_path, put_path],
            mutates=True,
        )
        ctx.run(["rm", "-f", tmp_path], mutates=True)
        if res.rc != 0:
            fail("failed to update user_data " + key + ": " + res.stderr)

    return {"changed": True, "msg": "successfully updated user_data for server " + server_id}
