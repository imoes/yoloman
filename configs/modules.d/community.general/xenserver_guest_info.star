def main(ctx, params):
    fail("xenserver_guest_info cannot be implemented in Starlark because it requires XenAPI library to communicate with XenServer host, which is not available through the Starlark runtime ctx interface. Use the original Python Ansible module instead.")
