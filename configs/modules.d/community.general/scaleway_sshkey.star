def main(ctx, params):
    api_token = params.get("api_token")
    if api_token == None:
        fail("api_token is required")
    
    ssh_pub_key = params.get("ssh_pub_key")
    if ssh_pub_key == None:
        fail("ssh_pub_key is required")

    state = params.get("state", "present")
    if state not in ["present", "absent"]:
        fail("state must be 'present' or 'absent'")

    api_url = params.get("api_url", "https://account.scaleway.com")
    if not api_url.startswith("http"):
        fail("api_url must start with http:// or https://")

    # Construct headers for API calls
    headers = {
        "X-Auth-Token": api_token,
        "Content-Type": "application/json"
    }

    # Get organization info (read-only probe)
    res = ctx.run([
        "curl", "-sS", "-X", "GET",
        api_url.rstrip("/") + "/organizations",
        "-H", "X-Auth-Token: " + api_token,
        "-H", "Content-Type: application/json"
    ])
    if res.rc != 0:
        fail("failed to fetch organizations: " + res.stderr)

    org_data = res.stdout
    if org_data.find('"organizations"') == -1:
        fail("invalid JSON response: missing organizations")
    
    # Extract user_id (first user id from first org)
    user_id_start = org_data.find('"users"')
    if user_id_start == -1:
        fail("invalid JSON response: missing users")
    users_section = org_data[user_id_start:]
    id_pos = users_section.find('"id"')
    if id_pos == -1:
        fail("invalid JSON response: missing user id")
    # Extract the id value (simple string between quotes after "id":)
    colon_pos = users_section.find(':', id_pos)
    quote1 = users_section.find('"', colon_pos + 1)
    quote2 = users_section.find('"', quote1 + 1)
    if quote1 == -1 or quote2 == -1:
        fail("invalid JSON response: malformed user id")
    user_id = users_section[quote1+1:quote2]

    # Extract present SSH keys
    ssh_keys = []
    key_section = org_data.find('"ssh_public_keys"')
    if key_section != -1:
        # Look for keys in format: {"key": "value"}
        pos = key_section
        while True:
            key_start = org_data.find('"key"', pos)
            if key_start == -1:
                break
            colon = org_data.find(':', key_start)
            quote1 = org_data.find('"', colon + 1)
            quote2 = org_data.find('"', quote1 + 1)
            if quote1 != -1 and quote2 != -1:
                ssh_keys.append(org_data[quote1+1:quote2])
            pos = quote2 + 1

    # Check state
    if state == "present":
        if ssh_pub_key in ssh_keys:
            return {"changed": False, "msg": "SSH key already present"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would add SSH key"}

        # Build payload
        new_keys = ssh_keys + [ssh_pub_key]
        payload = '{"ssh_public_keys": ['
        for i, key in enumerate(new_keys):
            if i > 0:
                payload += ', '
            payload += '{"key": "' + key + '"}'
        payload += ']}'

        # PATCH request to update user SSH keys
        cmd = [
            "curl", "-sS", "-X", "PATCH",
            api_url.rstrip("/") + "/users/" + user_id,
            "-H", "X-Auth-Token: " + api_token,
            "-H", "Content-Type: application/json",
            "-d", payload
        ]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would update SSH keys"}
        if res.rc != 0:
            fail("failed to update SSH keys: " + res.stderr)
        
        return {"changed": True, "msg": "SSH key added", "data": {"ssh_public_keys": [{"key": k} for k in new_keys]}}

    elif state == "absent":
        if ssh_pub_key not in ssh_keys:
            return {"changed": False, "msg": "SSH key not found"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove SSH key"}

        # Build payload without the key
        new_keys = [k for k in ssh_keys if k != ssh_pub_key]
        payload = '{"ssh_public_keys": ['
        for i, key in enumerate(new_keys):
            if i > 0:
                payload += ', '
            payload += '{"key": "' + key + '"}'
        payload += ']}'

        # PATCH request to update user SSH keys
        cmd = [
            "curl", "-sS", "-X", "PATCH",
            api_url.rstrip("/") + "/users/" + user_id,
            "-H", "X-Auth-Token: " + api_token,
            "-H", "Content-Type: application/json",
            "-d", payload
        ]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would update SSH keys"}
        if res.rc != 0:
            fail("failed to update SSH keys: " + res.stderr)
        
        return {"changed": True, "msg": "SSH key removed", "data": {"ssh_public_keys": [{"key": k} for k in new_keys]}}
