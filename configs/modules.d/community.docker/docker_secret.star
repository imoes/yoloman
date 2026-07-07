def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    data = params.get("data")
    data_src = params.get("data_src")
    data_is_b64 = params.get("data_is_b64", False)
    labels = params.get("labels")
    force = params.get("force", False)
    rolling_versions = params.get("rolling_versions", False)
    versions_to_keep = params.get("versions_to_keep", 5)

    # Validation
    if state == "present":
        if data != None and data_src != None:
            fail("data and data_src are mutually exclusive")
        if data == None and data_src == None:
            fail("one of data or data_src is required when state=present")

        if data_src != None:
            if not ctx.file_exists(data_src):
                fail("data_src file does not exist: " + data_src)
            data = ctx.file_read(data_src)
            # data is read as text; treat as binary if needed via b64
        # Handle data_is_b64: decode if requested
        if data_is_b64:
            # Simple base64 decode (standard chars only)
            # Starlark has no base64; fail for this unsupported feature
            fail("base64 decoding (data_is_b64) is not supported in Starlark")

    # Simulate docker secret idempotency with file-based storage for state
    # We store a file per secret in a predictable location (e.g., /var/run/docker-secrets)
    # For production use, replace with real Docker API integration via ctx.run
    # Since Docker API is not available via ctx, we simulate behavior only.

    # Check-mode: assume secret exists if file exists and matches hash
    if ctx.check_mode:
        if state == "absent":
            # Simulate: if secret exists, changed = True, else False
            return {"changed": True, "msg": "would remove secret " + name}
        # state == "present"
        return {"changed": True, "msg": "would create/update secret " + name}

    # Real execution (simulation)
    if state == "absent":
        # In real code: docker secret rm <name> or docker secret rm <name>_v*
        # Here: remove a dummy state file if exists
        return {"changed": False, "msg": "secret removal not implemented in this simulation"}

    if state == "present":
        # In real code: docker secret create or update
        # Here: simulate creation/update
        return {"changed": False, "msg": "secret creation/update not implemented in this simulation"}
