def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    poolid = params["poolid"]
    comment = params.get("comment")
    state = params.get("state", "present")
    validate_certs = params.get("validate_certs", False)

    # Token auth requires both or none
    if (api_token_id == None) != (api_token_secret == None):
        fail("api_token_id and api_token_secret must be provided together")
    if api_password == None and api_token_id == None:
        fail("one of api_password or api_token_id is required")

    # Build curl arguments for authentication
    auth_args = ["curl", "-s", "-k"]  # -k for validate_certs=False
    if validate_certs:
        auth_args = ["curl", "-s"]  # no -k when validating

    # Auth endpoint
    auth_url = "https://" + api_host + ":8006/api2/json/access/ticket"
    auth_data = "username=" + api_user + "&password=" + api_password if api_password else "username=" + api_user + "&token=" + api_token_id + "=" + api_token_secret

    # 1. Authenticate and get ticket
    auth_res = ctx.run(
        auth_args + [
            "-X", "POST",
            "-d", auth_data,
            "-H", "Content-Type: application/x-www-form-urlencoded",
            auth_url
        ]
    )
    if auth_res.rc != 0:
        fail("authentication failed: " + auth_res.stderr)

    # Parse JSON response manually (no json module)
    lines = auth_res.stdout.split("\n")
    ticket = ""
    csrf_prevention_token = ""
    for line in lines:
        if '"ticket"' in line:
            idx = line.find('"ticket"')
            start = line.find('"', idx + 9)
            end = line.find('"', start + 1)
            if start != -1 and end != -1:
                ticket = line[start + 1:end]
        if '"CSRFPreventionToken"' in line:
            idx = line.find('"CSRFPreventionToken"')
            start = line.find('"', idx + 22)
            end = line.find('"', start + 1)
            if start != -1 and end != -1:
                csrf_prevention_token = line[start + 1:end]
    if ticket == "":
        fail("failed to parse ticket from authentication response")
    if csrf_prevention_token == "":
        fail("failed to parse CSRFPreventionToken from authentication response")

    # Helper to run proxmox API calls with auth headers
    def proxmox_get(path):
        url = "https://" + api_host + ":8006" + path
        return ctx.run(
            auth_args + [
                "-X", "GET",
                "-H", "Cookie: PVEAuthCookie=" + ticket,
                url
            ]
        )

    def proxmox_post(path, data):
        url = "https://" + api_host + ":8006" + path
        return ctx.run(
            auth_args + [
                "-X", "POST",
                "-H", "Cookie: PVEAuthCookie=" + ticket,
                "-H", "CSRFPreventionToken: " + csrf_prevention_token,
                "-d", data,
                "-H", "Content-Type: application/x-www-form-urlencoded",
                url
            ]
        )

    def proxmox_delete(path):
        url = "https://" + api_host + ":8006" + path
        return ctx.run(
            auth_args + [
                "-X", "DELETE",
                "-H", "Cookie: PVEAuthCookie=" + ticket,
                "-H", "CSRFPreventionToken: " + csrf_prevention_token,
                url
            ]
        )

    # 2. Check if pool exists
    pools_res = proxmox_get("/api2/json/pools")
    if pools_res.rc != 0:
        fail("failed to retrieve pools: " + pools_res.stderr)

    # Parse pool IDs from response
    existing_pools = []
    for line in pools_res.stdout.split("\n"):
        if '"poolid"' in line:
            idx = line.find('"poolid"')
            start = line.find('"', idx + 8)
            end = line.find('"', start + 1)
            if start != -1 and end != -1:
                pid = line[start + 1:end]
                if pid not in existing_pools:
                    existing_pools.append(pid)

    pool_exists = poolid in existing_pools

    if state == "present":
        if pool_exists:
            return {"changed": False, "msg": "Pool " + poolid + " already exists", "poolid": poolid}

        if ctx.check_mode:
            return {"changed": True, "msg": "would create pool " + poolid, "poolid": poolid}

        # Build comment param for POST
        data = "poolid=" + poolid
        if comment != None:
            data += "&comment=" + comment

        create_res = proxmox_post("/api2/json/pools", data)
        if create_res.rc != 0:
            fail("failed to create pool " + poolid + ": " + create_res.stderr)

        return {"changed": True, "msg": "Pool " + poolid + " successfully created", "poolid": poolid}

    else:  # state == "absent"
        if not pool_exists:
            return {"changed": False, "msg": "Pool " + poolid + " doesn't exist", "poolid": poolid}

        # Check pool is empty (members check)
        pool_res = proxmox_get("/api2/json/pools/" + poolid)
        if pool_res.rc != 0:
            fail("failed to retrieve pool " + poolid + ": " + pool_res.stderr)

        # Parse members array from JSON (very simple)
        members_empty = True
        for line in pool_res.stdout.split("\n"):
            if '"members"' in line:
                idx = line.find('"members"')
                start = line.find('[', idx)
                end = line.find(']', start)
                if start != -1 and end != -1 and line[start:end+1] != "[]":
                    members_empty = False
                break

        if not members_empty:
            fail("can't delete pool " + poolid + " with members. Please remove members from pool first.")

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete pool " + poolid, "poolid": poolid}

        delete_res = proxmox_delete("/api2/json/pools/" + poolid)
        if delete_res.rc != 0:
            fail("failed to delete pool " + poolid + ": " + delete_res.stderr)

        return {"changed": True, "msg": "Pool " + poolid + " successfully deleted", "poolid": poolid}
