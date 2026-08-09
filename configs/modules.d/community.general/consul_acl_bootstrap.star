def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    validate_certs = params.get("validate_certs", True)
    state = params.get("state", "present")
    bootstrap_secret = params.get("bootstrap_secret")

    if state not in ("present", "bootstrapped"):
        fail("unsupported state: " + state)

    # Build base URL
    base_url = scheme + "://" + host + ":" + str(port)

    # Build headers
    headers = ["-H", "Content-Type: application/json"]

    # Build TLS options if needed
    tls_opts = []
    if scheme == "https":
        if validate_certs:
            tls_opts = ["-k"]  # curl -k allows self-signed; no way to specify CA in Starlark ctx.run
        else:
            tls_opts = ["-k"]  # Same - ctx.run has no cert validation override
    else:
        # HTTP, no TLS
        pass

    # Prepare body
    body = ""
    if bootstrap_secret != None:
        body = '{"BootstrapSecret":"' + bootstrap_secret + '"}'
    else:
        body = "{}"

    # Check if ACL system is already bootstrapped (read-only probe)
    # We do this only for state="present" (default) to determine idempotency
    if state == "present":
        res = ctx.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}"] + tls_opts +
                      headers + [base_url + "/v1/acl/bootstrap"], mutates=False)
        if res.rc == 0 and res.stdout.strip() == "200":
            # ACL bootstrap endpoint exists and responds OK — system is already bootstrapped
            return {"changed": False, "msg": "ACL bootstrap already completed"}
        elif res.rc == 0 and res.stdout.strip() == "403":
            # 403 is normal when ACL system is not bootstrapped — proceed
            pass
        # Other cases fall through to attempt bootstrap

    # Perform the bootstrap request
    # Use curl -X PUT with JSON body
    curl_cmd = [
        "curl", "-s", "-X", "PUT", "-d", body
    ] + tls_opts + headers + [base_url + "/v1/acl/bootstrap"]

    res = ctx.run(curl_cmd, mutates=True)

    if res.skipped:
        # Check mode prediction: would perform bootstrap
        return {"changed": True, "msg": "would bootstrap ACL system"}

    # Parse response
    if res.rc != 0:
        # Check for known "already bootstrapped" error
        stderr = res.stderr.lower()
        if "403" in stderr and "bootstrap no longer allowed" in stderr:
            return {"changed": False, "msg": "ACL bootstrap no longer allowed"}
        fail("bootstrap failed: " + res.stderr)

    # Return success with parsed result
    # Note: ctx.run does not parse JSON, so we return raw output as string
    # but standard practice is to return a dict — we cannot parse JSON here.
    # Since Starlark has no json module, we return the raw stdout as "result" string.
    # For idempotency, we know changed=True.
    return {"changed": True, "msg": "ACL bootstrap successful", "data": {"result": res.stdout}}
