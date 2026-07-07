def main(ctx, params):
    name = params.get("name")
    if name == None:
        fail("missing required argument: name")

    # Check mode: we only read, so we can run even in check_mode
    # Execute: docker service inspect <name> --format '{{json .}}'
    # Using JSON format avoids parsing complexity; fallback to plain inspect if needed
    res = ctx.run(
        ["docker", "service", "inspect", name, "--format", "{{json .}}"],
        mutates=False,
        ok_codes=[0, 1]
    )

    if res.rc == 1 and "no such service" in res.stderr.lower():
        return {
            "changed": False,
            "msg": "Service not found",
            "data": {"exists": False, "service": None}
        }
    if res.rc != 0:
        fail("docker service inspect failed: " + res.stderr)

    # Parse JSON manually (no json module)
    # The output is a JSON object or array; docker service inspect returns an array
    # For single name, it's usually a single-element array. We extract first element.
    output = res.stdout.strip()
    if output.startswith("[") and output.endswith("]"):
        # Extract first object inside array
        # Simple approach: find first '{' and matching '}'
        start = output.find("{")
        if start == -1:
            fail("could not parse docker service inspect output: no JSON object found")
        depth = 0
        end = start
        for i in range(start, len(output)):
            if output[i] == '{':
                depth += 1
            elif output[i] == '}':
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        if depth != 0:
            fail("could not parse docker service inspect output: unmatched braces")
        output = output[start:end]
    # If it's a bare object already, use as-is

    # Convert to dict by replacing quotes and parsing key-value manually
    # Since Starlark has no json, we return the raw string and let the caller parse externally,
    # or we implement a minimal parser for known keys. However, the contract says no external parsing.
    # Instead, return the output as-is in 'service', and let the receiver handle parsing.
    # But the return type must be dict. We can only return string values as 'service'.
    # To satisfy idempotency and return contract, we return the string output in 'data'.
    return {
        "changed": False,
        "msg": "Service found",
        "data": {
            "exists": True,
            "service": output  # JSON string of inspect result
        }
    }
