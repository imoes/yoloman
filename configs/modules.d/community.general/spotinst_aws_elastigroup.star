def main(ctx, params):
    # Note: This module requires the spotinst_sdk Python library, which is not available in Starlark.
    # The module cannot function without it, so fail with a clear message.
    fail("module spotinst_aws_elastigroup cannot run in Starlark: requires spotinst_sdk Python library")
