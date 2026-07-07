def main(ctx, params):
    host = params.get("host", "127.0.0.1")
    username = params.get("username", "cobbler")
    password = params.get("password")
    use_ssl = params.get("use_ssl", True)
    validate_certs = params.get("validate_certs", True)
    name = params.get("name")
    state = params.get("state", "present")
    port = params.get("port")
    sync = params.get("sync", False)

    proto = "https" if use_ssl else "http"
    if port == None:
        port = 443 if use_ssl else 80

    url = "{proto}://{host}:{port}/cobbler_api".format(proto=proto, host=host, port=port)

    # Build curl command to call Cobbler API
    # Login first
    login_cmd = ["curl", "-s", "-S", "-k" if not validate_certs else "", "-d", "username=" + username, "-d", "password=" + password, url + "/login"]
    login_cmd = [x for x in login_cmd if x != ""]
    res = ctx.run(login_cmd)
    if res.rc != 0:
        fail("Failed to log in to Cobbler at " + url + ": " + res.stderr)

    # Extract token
    token = ""
    lines = res.stdout.split("\n")
    for line in lines:
        if line.startswith("token="):
            token = line.strip().split("=", 1)[1]
            break
    if not token:
        fail("Failed to extract token from Cobbler login response")

    # Helper to make API calls
    def cobbler_api(method, params_dict=None):
        if params_dict == None:
            params_dict = {}
        # Build JSON payload
        payload_items = ["token=" + token]
        for k, v in params_dict.items():
            # Escape special chars for shell
            v_escaped = v.replace("'", "'\"'\"'")
            payload_items.append(k + "='" + v_escaped + "'")
        payload = " & ".join(payload_items)
        cmd = ["curl", "-s", "-S", "-k" if not validate_certs else "", "-d", payload, url + "/" + method]
        cmd = [x for x in cmd if x != ""]
        return ctx.run(cmd)

    # Query existing system if name provided
    existing_system = {}
    if name:
        res = cobbler_api("find_system", {"name": name})
        if res.rc != 0:
            fail("Failed to query system " + name + ": " + res.stderr)
        if res.stdout.strip():
            # Simplified parsing: assume first JSON object
            # Cobbler returns a list of dicts — take first
            existing_system = res.stdout.strip()

    if state == "query":
        if name:
            return {"changed": False, "msg": "system " + name + " queried", "system": existing_system}
        else:
            res = cobbler_api("get_systems")
            if res.rc != 0:
                fail("Failed to list systems: " + res.stderr)
            systems = res.stdout.strip()
            return {"changed": False, "msg": "systems queried", "systems": systems}

    elif state == "present":
        if existing_system:
            # Update — parse properties and compare
            changed = False
            properties = params.get("properties")
            if properties:
                for key, value in properties.items():
                    # Simple diff: assume value changed if not equal (string comparison)
                    # In real implementation would need deeper diff
                    if str(existing_system.get(key)) != str(value):
                        res = cobbler_api("modify_system", {"system": name, "property": key, "value": value})
                        if res.rc != 0:
                            fail("Failed to set property " + key + ": " + res.stderr)
                        changed = True

            interfaces = params.get("interfaces")
            if interfaces:
                for device, ifprops in interfaces.items():
                    for key, value in ifprops.items():
                        # Map interface property names if needed
                        # For now: assume no mapping needed
                        if_key = device + "-" + key
                        if str(existing_system.get(if_key)) != str(value):
                            # Build modify_interface call (simplified)
                            res = cobbler_api("modify_system", {"system": name, "interface": device, "property": key, "value": value})
                            if res.rc != 0:
                                fail("Failed to set interface property " + key + " on " + device + ": " + res.stderr)
                            changed = True

            if not ctx.check_mode and changed:
                res = cobbler_api("save_system", {"system": name})
                if res.rc != 0:
                    fail("Failed to save system " + name + ": " + res.stderr)

            if ctx.check_mode:
                # Predict changed based on comparison above
                # Since we can't do full diff, assume changed if properties or interfaces passed and non-empty
                if params.get("properties") or params.get("interfaces"):
                    return {"changed": True, "msg": "would update system " + name}
                return {"changed": False, "msg": "system " + name + " already present"}

            return {"changed": changed, "msg": "updated system " + name}

        else:
            # Create new system
            res = cobbler_api("new_system", {"name": name})
            if res.rc != 0:
                fail("Failed to create new system " + name + ": " + res.stderr)

            changed = True
            properties = params.get("properties")
            if properties:
                for key, value in properties.items():
                    res = cobbler_api("modify_system", {"system": name, "property": key, "value": value})
                    if res.rc != 0:
                        fail("Failed to set property " + key + ": " + res.stderr)

            interfaces = params.get("interfaces")
            if interfaces:
                for device, ifprops in interfaces.items():
                    for key, value in ifprops.items():
                        res = cobbler_api("modify_system", {"system": name, "interface": device, "property": key, "value": value})
                        if res.rc != 0:
                            fail("Failed to set interface property " + key + " on " + device + ": " + res.stderr)

            if not ctx.check_mode:
                res = cobbler_api("save_system", {"system": name})
                if res.rc != 0:
                    fail("Failed to save new system " + name + ": " + res.stderr)

            if ctx.check_mode:
                return {"changed": True, "msg": "would create system " + name}

            return {"changed": changed, "msg": "created system " + name}

    elif state == "absent":
        if existing_system:
            if not ctx.check_mode:
                res = cobbler_api("remove_system", {"name": name})
                if res.rc != 0:
                    fail("Failed to remove system " + name + ": " + res.stderr)
            return {"changed": True, "msg": "would remove system " + name} if ctx.check_mode else {"changed": True, "msg": "removed system " + name}
        else:
            return {"changed": False, "msg": "system " + name + " does not exist"}

    else:
        fail("unsupported state: " + state)
