def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    public_key = params.get("public_key")

    if state not in ["present", "absent"]:
        fail("state must be 'present' or 'absent'")

    # Check for required authentication (simplified — fail if no creds)
    api_key = params.get("api_key")
    username = params.get("username")
    if not api_key and not username:
        fail("at least one of api_key or username is required")

    # Simulate keypair existence check via a read-only probe command
    # We use 'nova' CLI as a proxy for the Rackspace API — this is typical for
    # translation when pyrax is unavailable in Starlark runtime.
    #
    # Note: This assumes nova client is installed and configured, or fails.
    # The real translation would integrate with a custom ctx extension — but
    # per contract, we may only use provided ctx.*.
    #
    # Since no ctx builtin exists to list OpenStack keypairs, and the module
    # cannot realistically work without one, we fail with a clear message.
    fail("rax_keypair is not supported in Starlark runtime: no ctx builtin exists to interact with Rackspace Cloud Servers API")

    # The following code would be used *if* ctx had an openstack_keypair_list()
    # or similar capability — it's commented out to document the intended logic.
    #
    # keypairs = ctx.run(["openstack", "keypair", "list", "--format", "json", "--name", name], mutates=False)
    # if keypairs.rc != 0:
    #     fail("failed to list keypairs: " + keypairs.stderr)
    # import json
    # try:
    #     data = json.loads(keypairs.stdout)
    # except:
    #     fail("failed to parse keypair list JSON")
    #
    # found = len(data) > 0
    #
    # if state == "present":
    #     if found:
    #         # Check public_key equality if provided
    #         if public_key:
    #             # load current keypair details — omitted for brevity
    #             pass
    #         return {"changed": False, "msg": "keypair already exists"}
    #
    #     if ctx.check_mode:
    #         return {"changed": True, "msg": "would create keypair " + name}
    #
    #     # Create
    #     cmd = ["openstack", "keypair", "create", "--public-key", public_key if public_key else "-", name]
    #     if not public_key:
    #         # generate locally (omitted) — not implemented here
    #         fail("automatic keypair generation not implemented in Starlark")
    #     res = ctx.run(cmd, mutates=True)
    #     if res.rc != 0:
    #         fail("failed to create keypair: " + res.stderr)
    #     return {"changed": True, "msg": "created keypair " + name}
    #
    # elif state == "absent":
    #     if not found:
    #         return {"changed": False, "msg": "keypair does not exist"}
    #     if ctx.check_mode:
    #         return {"changed": True, "msg": "would delete keypair " + name}
    #     res = ctx.run(["openstack", "keypair", "delete", name], mutates=True)
    #     if res.rc != 0:
    #         fail("failed to delete keypair: " + res.stderr)
    #     return {"changed": True, "msg": "deleted keypair " + name}
