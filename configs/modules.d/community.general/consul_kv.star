def main(ctx, params):
    key = params["key"]
    state = params.get("state", "present")
    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    validate_certs = params.get("validate_certs", True)
    token = params.get("token")
    session = params.get("session")
    value = params.get("value")
    recurse = params.get("recurse")
    retrieve = params.get("retrieve", True)
    cas = params.get("cas")
    flags = params.get("flags")

    if validate_certs == False:
        fail("validate_certs=False is not supported in Starlark")

    # Build base URL for consul KV API
    base_url = scheme + "://" + host + ":" + str(port)
    kv_url = base_url + "/v1/kv/" + key
    if recurse:
        kv_url = kv_url + "?recurse=1"

    # Helper to build curl arguments
    def build_curl_cmd(method, extra_params=""):
        cmd = ["curl", "-s", "-S", "-X", method]
        if token != None:
            cmd.extend(["-H", "X-Consul-Token:" + token])
        if method == "GET" or method == "DELETE":
            cmd.append(kv_url)
            if extra_params != "":
                cmd[-1] = cmd[-1] + "?" + extra_params
        else:  # PUT
            cmd.append(kv_url)
            if extra_params != "":
                cmd[-1] = cmd[-1] + "?" + extra_params
        return cmd

    # GET current value
    def get_current():
        cmd = build_curl_cmd("GET")
        res = ctx.run(cmd, ok_codes=[0, 404])
        if res.rc != 0:
            fail("failed to query consul kv: " + res.stderr)
        if res.stdout.strip() == "":
            return None, False
        # Parse JSON manually (simple cases only)
        output = res.stdout.strip()
        if output.startswith("["):
            # Recurse mode: list of entries
            if output == "[]":
                return None, False
            # Extract Value fields from entries - simplified
            # Expected format: [{"Key": "...", "Value": "base64", ...}, ...]
            # We'll just return the raw output and let caller decide
            return output, True
        elif output.startswith("{"):
            # Single entry
            # Extract Value field - basic parsing
            val_start = output.find('"Value":')
            if val_start == -1:
                return None, False
            val_part = output[val_start + 8:].strip()
            if val_part.startswith("null"):
                return None, True
            # Extract string value between quotes
            if val_part.startswith('"'):
                end_quote = val_part.find('"', 1)
                if end_quote > 0:
                    encoded_val = val_part[1:end_quote]
                    # Decode base64 manually not available in Starlark
                    # Consul stores value in base64 - but we'll return the string representation
                    # In practice, this module often expects raw bytes decoded as UTF-8
                    return encoded_val, True
            return None, True
        return None, False

    # PUT value
    def put_value(val, extra_params=""):
        cmd = build_curl_cmd("PUT", extra_params)
        cmd.extend(["-d", val])
        res = ctx.run(cmd, ok_codes=[0])
        if res.rc != 0:
            fail("failed to write to consul kv: " + res.stderr)
        # Consul returns "true" or "false" on success/failure
        if res.stdout.strip() == "true":
            return True
        return False

    # DELETE value
    def delete_value():
        cmd = build_curl_cmd("DELETE")
        res = ctx.run(cmd, ok_codes=[0])
        if res.rc != 0:
            fail("failed to delete from consul kv: " + res.stderr)
        if res.stdout.strip() == "true":
            return True
        return False

    # Check mode handling
    if ctx.check_mode:
        if state == "absent":
            _, exists = get_current()
            if exists:
                return {"changed": True, "msg": "would delete key " + key}
            else:
                return {"changed": False, "msg": "key already absent"}
        elif state == "present":
            if value == None:
                # Just retrieve
                _, exists = get_current()
                return {"changed": False, "msg": "would retrieve key " + key}
            else:
                current_val, _ = get_current()
                if current_val == value:
                    return {"changed": False, "msg": "value already set for " + key}
                else:
                    return {"changed": True, "msg": "would update value for " + key}
        elif state in ["acquire", "release"]:
            if session == None:
                fail("session is required for acquire/release")
            _, exists = get_current()
            if state == "acquire":
                changed = not exists
            else:  # release
                changed = exists
            return {"changed": changed, "msg": "would " + state + " lock"}
        else:
            fail("unsupported state: " + state)

    # Actual state handling
    if state == "absent":
        _, exists = get_current()
        if not exists:
            return {"changed": False, "msg": "key already absent"}
        deleted = delete_value()
        if not deleted:
            fail("consul reported deletion failed")
        return {"changed": True, "msg": "deleted key " + key}

    elif state == "present":
        if value == None:
            # Retrieve only
            val, exists = get_current()
            return {"changed": False, "msg": "retrieved key " + key, "data": val}
        else:
            # Set value
            current_val, _ = get_current()
            if current_val == value:
                if retrieve:
                    _, stored = get_current()
                    return {"changed": False, "msg": "value already set", "data": stored}
                else:
                    return {"changed": False, "msg": "value already set"}
            # Need to update
            put_value(value)
            if retrieve:
                _, stored = get_current()
                return {"changed": True, "msg": "updated value", "data": stored}
            return {"changed": True, "msg": "updated value"}

    elif state in ["acquire", "release"]:
        if session == None:
            fail("session is required for acquire/release")
        extra_params = []
        if cas != None:
            extra_params.append("cas=" + str(cas))
        if flags != None:
            extra_params.append("flags=" + str(flags))
        if state == "acquire":
            extra_params.append("acquire=" + session)
        else:  # release
            extra_params.append("release=" + session)

        if not put_value(value if value != None else "", "&".join(extra_params)):
            # Consul returns false on CAS mismatch or lock contention
            return {"changed": False, "msg": state + " attempt failed"}
        return {"changed": True, "msg": "lock " + state + "d successfully"}

    else:
        fail("unsupported state: " + state)
