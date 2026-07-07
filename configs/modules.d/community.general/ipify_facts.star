def main(ctx, params):
    api_url = params.get("api_url", "https://api.ipify.org/")
    timeout = params.get("timeout", 10)
    validate_certs = params.get("validate_certs", True)

    # Build full URL with ?format=json suffix as required
    full_url = api_url + "?format=json"

    # Prepare HTTP options — note: validate_certs=False is not supported by ctx.run
    # In Starlark ctx, SSL verification cannot be disabled; fail if user requested it
    if not validate_certs:
        fail("validate_certs=false is not supported in this Starlark implementation")

    # Run read-only HTTP GET request
    res = ctx.run(
        ["curl", "-sSfL", "--connect-timeout", str(timeout), full_url],
        mutates=False
    )

    if res.rc != 0:
        fail("No valid response from url %s within %s seconds (timeout)" % (full_url, timeout))

    # Parse JSON response manually (no json module) — assume simple flat JSON
    stdout = res.stdout
    # Strip leading/trailing whitespace
    stdout = stdout.strip()
    if not stdout.startswith("{") or not stdout.endswith("}"):
        fail("Unexpected response format from %s: %s" % (full_url, stdout))

    # Extract "ip":"..." value using string search (simple and robust)
    key = '"ip":"'
    start = stdout.find(key)
    if start == -1:
        fail("Missing 'ip' field in response: %s" % stdout)
    start += len(key)
    end = stdout.find('"', start)
    if end == -1:
        fail("Malformed JSON: missing closing quote after ip value")
    public_ip = stdout[start:end]

    # Return result as facts (no changed state, pure facts module)
    return {
        "changed": False,
        "msg": "",
        "data": {
            "ipify_public_ip": public_ip
        }
    }
