def main(ctx, params):
    fail("xenserver_guest module is not yet implemented in Starlark. It requires XenAPI library which is not available in the Starlark runtime. Use the original Ansible module or implement a custom solution using ctx.run() to call xe CLI commands directly.")
