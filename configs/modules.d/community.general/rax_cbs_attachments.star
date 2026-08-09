def main(ctx, params):
    # Required params
    volume_id = params.get("volume")
    server_id = params.get("server")
    state = params.get("state", "present")

    if volume_id == None or server_id == None:
        fail("volume and server are required")

    # Optional params
    device = params.get("device")
    wait = params.get("wait", False)
    wait_timeout = params.get("wait_timeout", 300)

    # Check state validity
    if state not in ["present", "absent"]:
        fail("unsupported state: " + state + ", must be 'present' or 'absent'")

    # Note: This module cannot be implemented without a pyrax-like interface.
    # The original module depends on the pyrax library for Rackspace OpenStack APIs,
    # which is not available in Starlark. Since Starlark cannot make arbitrary HTTP
    # requests or use Python extensions, we must fail.
    fail("rax_cbs_attachments is not supported in Starlark - requires pyrax library for Rackspace APIs")
