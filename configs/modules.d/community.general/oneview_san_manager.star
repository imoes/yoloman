def main(ctx, params):
    state = params.get("state", "present")
    data = params.get("data")
    if data == None:
        fail("data is required")

    # Extract resource name from data: prefer Host in connectionInfo, else 'name'
    resource_name = None
    connection_info = data.get("connectionInfo")
    if connection_info != None:
        for item in connection_info:
            if type(item) == "dict" and item.get("name") == "Host":
                resource_name = item.get("value")
                break
    if resource_name == None:
        resource_name = data.get("name")
    if resource_name == None:
        fail('A "name" or "connectionInfo" must be provided inside the "data" field. If connectionInfo is provided, Host value is used as resource name.')

    # Determine OneView API endpoint base URL from environment or parameters
    # For this translation, we assume a preconfigured client (e.g., via env vars or config file)
    # Since Starlark cannot read files or env vars directly, this module expects that the
    # OneView API is accessible via a pre-configured URL (e.g., via ctx.facts() or other setup).
    # For simplicity, we define a placeholder endpoint construction and use ctx.run to call HTTP APIs.
    # In practice, the yolo-man runtime would inject a ready-to-use HTTP client — but per contract,
    # we only have ctx.run, so we must simulate HTTP with CLI tools.
    # However, since OneView is an HTTP API and ctx.run does not support HTTP, this module
    # CANNOT be correctly implemented with only ctx.* builtins unless the runtime provides a custom
    # HTTP helper. Per the contract, we must fail with a clear message.
    fail("oneview_san_manager cannot be implemented in pure Starlark without an HTTP client. Use a custom runtime helper or CLI wrapper for OneView REST API calls.")

    # NOTE: The original Python module depends on hpOneView client library (REST API calls).
    # This Starlark translation cannot replace it because:
    #   - ctx.run only executes local commands (no HTTP)
    #   - no stdlib networking (no urllib/requests)
    #   - no way to authenticate, handle ETags, or parse JSON responses
    # A real integration would require a custom ctx.http_get/ctx.http_post/etc. or CLI tool.
    # Until then, the module is not translatable to Starlark under the given contract.
