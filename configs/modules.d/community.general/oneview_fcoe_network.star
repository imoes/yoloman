def main(ctx, params):
    state = params.get("state", "present")
    data = params.get("data")
    if data == None:
        fail("data is required")
    name = data.get("name")
    if name == None:
        fail("data.name is required")

    # Build base API URL (no external client; simulate via ctx.run)
    # Since OneView API calls require auth and complex headers, we rely on a
    # helper script: 'oneview_cli' that understands the config/credentials
    # and returns JSON. This is a realistic approximation for Starlark translation.
    def oneview_cmd(args, mutates=False):
        full_args = ["oneview_cli", "fcoe_network"] + args
        res = ctx.run(full_args, mutates=mutates)
        if res.rc != 0:
            fail("oneview_cli failed: " + res.stderr)
        # Expect JSON in stdout
        return res.stdout

    # Ensure data is dict-like and name is string
    if type(data) != "dict":
        fail("data must be a dict")

    # Get current resource by name
    get_res = oneview_cmd(["get", name], mutates=False)
    existing = None
    if get_res.strip() != "":
        existing = get_res  # raw JSON string (passed through as needed)

    if state == "present":
        if existing != None:
            # Update: compare minimal fields (name only for simplicity; real impl would diff full payload)
            # For idempotency, we assume if resource exists with same name and no major change is needed,
            # we do nothing unless etag or content differs.
            # Since we cannot diff complex JSON here without a proper library, we rely on OneView's PATCH semantics.
            # In practice, we always PATCH with full data if etag validation is enabled or not.
            # For simplicity in Starlark: always PATCH unless content exactly matches (rarely true).
            # Use PATCH with full data; OneView returns 200 if no change.
            payload = oneview_cmd(["update", name, "--json", str(data)], mutates=True)
            changed = True
            return {"changed": changed, "msg": "FCoE Network updated successfully.", "data": payload}
        else:
            # Create
            payload = oneview_cmd(["create", "--json", str(data)], mutates=True)
            return {"changed": True, "msg": "FCoE Network created successfully.", "data": payload}

    if state == "absent":
        if existing == None:
            return {"changed": False, "msg": "FCoE Network is already absent."}
        oneview_cmd(["delete", name], mutates=True)
        return {"changed": True, "msg": "FCoE Network deleted successfully."}

    fail("unsupported state: " + state)
