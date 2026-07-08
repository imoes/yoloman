def main(ctx, params):
    name = params.get("name")
    params_dict = params.get("params", {})

    # Build query args for get_all
    query_kwargs = {}
    allowed_keys = ["start", "count", "filter", "sort"]
    for key in allowed_keys:
        if key in params_dict:
            query_kwargs[key] = params_dict[key]

    # Authentication: prefer explicit creds over env vars (via ctx.run)
    # We'll construct a oneview-cli-like call; assume 'oneview-cli' is available
    # and uses environment variables for auth when no explicit args provided.
    # Since Starlark cannot directly call the OneView SDK, we simulate via CLI.
    # NOTE: This assumes a CLI wrapper around OneView exists — if not, this fails.

    # Construct command base
    cmd = ["oneview-cli", "fc-network", "list", "--output-format", "json"]

    # Add --name if provided (filter by name)
    if name != None:
        cmd.extend(["--name", str(name)])

    # Add query flags
    if "start" in query_kwargs:
        cmd.extend(["--start", str(query_kwargs["start"])])
    if "count" in query_kwargs:
        cmd.extend(["--count", str(query_kwargs["count"])])
    if "filter" in query_kwargs:
        cmd.extend(["--filter", str(query_kwargs["filter"])])
    if "sort" in query_kwargs:
        cmd.extend(["--sort", str(query_kwargs["sort"])])

    # In check_mode: just simulate success and return empty if no name
    if ctx.check_mode:
        # Read-only probe — assume CLI would succeed
        res = ctx.run(cmd + ["--dry-run"], mutates=False)
        # If --dry-run not supported, fallback to real run (read-only)
        if res.rc != 0 and res.stderr.find("dry-run") != -1:
            res = ctx.run(cmd, mutates=False)
        if res.rc != 0:
            fail("failed to probe fc networks: " + res.stderr)
        # Predict change = False, return placeholder result
        return {"changed": False, "msg": "would fetch fc networks", "data": {"fc_networks": []}}

    # Actual fetch (non-check-mode)
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("failed to list fc networks: " + res.stderr)

    # Parse JSON output manually (no json module)
    # Assume output is newline-delimited JSON objects or a JSON array.
    # For simplicity, expect a single JSON array.
    output = res.stdout.strip()
    if output == "":
        fc_networks = []
    else:
        # Naive JSON array parsing (assumes well-formed single top-level array)
        if not (output.startswith("[") and output.endswith("]")):
            fail("unexpected fc-network output: not a JSON array")
        # Strip brackets and split by '}, {' but this is fragile.
        # Safer: rely on ctx.run returning structured data via --output-format.
        # Since Starlark lacks JSON parser, we cannot parse arbitrary JSON.
        # Therefore: fail with helpful message if not simple enough.
        fail("this module requires a JSON parser — not available in Starlark. Please use a custom CLI or helper.")
        # NOTE: In real deployment, you'd add a helper script that outputs plain text or
        # a simple key=value list, avoiding JSON in Starlark.

    return {"changed": False, "msg": "fetched fc networks successfully", "data": {"fc_networks": fc_networks}}
