def main(ctx, params):
    pritunl_url = params["pritunl_url"]
    pritunl_api_token = params["pritunl_api_token"]
    pritunl_api_secret = params["pritunl_api_secret"]
    org_name = params["organization"]
    user_name = params["user_name"]
    state = params.get("state", "present")
    user_email = params.get("user_email")
    user_type = params.get("user_type", "client")
    user_groups = params.get("user_groups")
    user_disabled = params.get("user_disabled")
    user_gravatar = params.get("user_gravatar")
    user_mac_addresses = params.get("user_mac_addresses")
    validate_certs = params.get("validate_certs", True)

    # Helper to call Pritunl API with curl
    def pritunl_call(path, method="GET", data=None):
        args = ["curl", "-s", "-k", "-X", method]
        args.extend(["-H", "Content-Type:application/json"])
        args.extend(["-H", "API-Token:" + pritunl_api_token])
        args.extend(["-H", "API-Secret:" + pritunl_api_secret])
        if data != None:
            args.extend(["--data", data])
        args.append(pritunl_url + path)
        res = ctx.run(args)
        if res.rc != 0:
            fail("Pritunl API request failed: " + res.stderr)
        return res.stdout.strip()

    # Step 1: Find organization ID
    orgs_json = pritunl_call("/organization?name=" + org_name)
    orgs = orgs_json.splitlines()
    if len(orgs) == 0:
        fail("Organization '%s' does not exist" % org_name)
    
    # Extract org_id from first org JSON object
    org_json = orgs[0]
    id_idx = org_json.find('"id":"')
    if id_idx == -1:
        fail("Could not parse organization ID from: %s" % org_json)
    id_start = id_idx + 6
    id_end = org_json.find('"', id_start)
    if id_end == -1:
        fail("Invalid organization JSON: %s" % org_json)
    org_id = org_json[id_start:id_end]

    # Step 2: Check if user exists
    users_json = pritunl_call("/organization/" + org_id + "/user?name=" + user_name)
    users = users_json.splitlines()
    user_exists = len(users) > 0
    user_id = ""
    
    if user_exists:
        user_json = users[0]
        id_idx = user_json.find('"id":"')
        if id_idx == -1:
            fail("Could not parse user ID from: %s" % user_json)
        id_start = id_idx + 6
        id_end = user_json.find('"', id_start)
        if id_end == -1:
            fail("Invalid user JSON: %s" % user_json)
        user_id = user_json[id_start:id_end]

    # Helper to build user JSON body for POST/PUT
    def build_user_json():
        parts = ['{"name":"%s"' % user_name]
        if user_email != None:
            parts.append(',"email":"%s"' % user_email)
        if user_type != None:
            parts.append(',"type":"%s"' % user_type)
        if user_disabled != None:
            parts.append(',"disabled":%s' % ("true" if user_disabled else "false"))
        if user_gravatar != None:
            parts.append(',"gravatar":%s' % ("true" if user_gravatar else "false"))
        if user_groups != None:
            groups_str = ""
            for i in range(len(user_groups)):
                if i > 0:
                    groups_str = groups_str + ","
                groups_str = groups_str + '"%s"' % user_groups[i]
            parts.append(',"groups":[%s]' % groups_str)
        if user_mac_addresses != None:
            macs_str = ""
            for i in range(len(user_mac_addresses)):
                if i > 0:
                    macs_str = macs_str + ","
                macs_str = macs_str + '"%s"' % user_mac_addresses[i]
            parts.append(',"mac_addresses":[%s]' % macs_str)
        parts.append("}")
        return "".join(parts)

    # Handle state
    if state == "present":
        if user_exists:
            # Parse current user fields for comparison
            current = users[0]
            needs_update = False

            # Email comparison
            if user_email != None:
                expected_email = '"email":"%s"' % user_email
                if current.find(expected_email) == -1:
                    needs_update = True

            # Type comparison (only if not client)
            if user_type != None and user_type != "client":
                expected_type = '"type":"%s"' % user_type
                if current.find(expected_type) == -1:
                    needs_update = True

            # Disabled comparison
            if user_disabled != None:
                expected_disabled = '"disabled":%s' % ("true" if user_disabled else "false")
                if current.find(expected_disabled) == -1:
                    needs_update = True

            # Gravatar comparison
            if user_gravatar != None:
                expected_gravatar = '"gravatar":%s' % ("true" if user_gravatar else "false")
                if current.find(expected_gravatar) == -1:
                    needs_update = True

            # Groups comparison (order-insensitive)
            if user_groups != None:
                current_groups = []
                groups_idx = current.find('"groups":[')
                if groups_idx != -1:
                    end = current.find("]", groups_idx)
                    if end != -1:
                        groups_content = current[groups_idx + 10:end]
                        if len(groups_content) > 0:
                            for part in groups_content.split(","):
                                part = part.strip()
                                if len(part) > 0:
                                    current_groups.append(part.strip('"'))
                if set(current_groups) != set(user_groups):
                    needs_update = True

            # MAC addresses comparison (order-insensitive)
            if user_mac_addresses != None:
                current_macs = []
                macs_idx = current.find('"mac_addresses":[')
                if macs_idx != -1:
                    end = current.find("]", macs_idx)
                    if end != -1:
                        macs_content = current[macs_idx + 16:end]
                        if len(macs_content) > 0:
                            for part in macs_content.split(","):
                                part = part.strip()
                                if len(part) > 0:
                                    current_macs.append(part.strip('"'))
                if set(current_macs) != set(user_mac_addresses):
                    needs_update = True

            if needs_update:
                user_json = build_user_json()
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update user %s" % user_name}
                res = ctx.run(["curl", "-s", "-k", "-X", "PUT", "-H", "Content-Type:application/json", "-H", "API-Token:" + pritunl_api_token, "-H", "API-Secret:" + pritunl_api_secret, "--data", user_json, pritunl_url + "/organization/" + org_id + "/user/" + user_id])
                if res.rc != 0:
                    fail("Failed to update user: %s" % res.stderr)
                return {"changed": True, "msg": "updated user %s" % user_name}
            else:
                return {"changed": False, "msg": "user %s already present" % user_name}
        else:
            # Create user
            user_json = build_user_json()
            if ctx.check_mode:
                return {"changed": True, "msg": "would create user %s" % user_name}
            res = ctx.run(["curl", "-s", "-k", "-X", "POST", "-H", "Content-Type:application/json", "-H", "API-Token:" + pritunl_api_token, "-H", "API-Secret:" + pritunl_api_secret, "--data", user_json, pritunl_url + "/organization/" + org_id + "/user"])
            if res.rc != 0:
                fail("Failed to create user: %s" % res.stderr)
            return {"changed": True, "msg": "created user %s" % user_name}

    elif state == "absent":
        if not user_exists:
            return {"changed": False, "msg": "user %s not found" % user_name}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete user %s" % user_name}
            res = ctx.run(["curl", "-s", "-k", "-X", "DELETE", "-H", "API-Token:" + pritunl_api_token, "-H", "API-Secret:" + pritunl_api_secret, pritunl_url + "/organization/" + org_id + "/user/" + user_id])
            if res.rc != 0:
                fail("Failed to delete user: %s" % res.stderr)
            return {"changed": True, "msg": "deleted user %s" % user_name}

    else:
        fail("Unsupported state: " + state)
