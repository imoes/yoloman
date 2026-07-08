def main(ctx, params):
    label = params.get("label")
    if label == None:
        fail("label is required")
    state = params.get("state", "present")
    if state not in ["present", "absent"]:
        fail("state must be one of: present, absent")
    cidr = params.get("cidr")

    if ctx.check_mode:
        fail("check_mode is not supported by rax_network")

    # This module requires pyrax (Python library) which cannot be used in Starlark.
    fail("This module requires pyrax (Python library), which cannot be used in Starlark. Use the original Ansible module.")
