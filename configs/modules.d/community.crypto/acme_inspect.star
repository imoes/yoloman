def main(ctx, params):
    # Required params
    acme_directory = params["acme_directory"]
    acme_version = params["acme_version"]
    method = params.get("method", "get")
    url = params.get("url")
    content = params.get("content")

    # Validation
    if method == "directory-only":
        if url != None:
            fail("url must not be specified when method=directory-only")
        if content != None:
            fail("content must not be specified when method=directory-only")
    else:
        if url == None:
            fail("url is required when method is not directory-only")
        if method == "post" and content == None:
            fail("content is required when method=post")

    # Account key handling
    account_key_src = params.get("account_key_src")
    account_key_content = params.get("account_key_content")
    account_key_passphrase = params.get("account_key_passphrase")
    account_uri = params.get("account_uri")
    if account_key_src == None and account_key_content == None:
        fail("One of account_key_src or account_key_content is required")
    if account_key_src != None and account_key_content != None:
        fail("account_key_src and account_key_content are mutually exclusive")

    # Temp file for key content (if needed)
    key_file = None
    if account_key_content != None:
        key_file = "/tmp/acme_inspect_account_key_" + str(ctx.facts().get("hostname", "localhost")) + ".pem"
        changed = ctx.file_write(key_file, account_key_content, "0600")
        if changed and ctx.check_mode:
            ctx.file_write(key_file, "", "0600")  # ensure temp file is cleaned up properly in check_mode
            return {"changed": True, "msg": "would write account key to temporary file"}

    # Build openssl command args
    # Backend selection (cryptography not available in Starlark → fallback to openssl binary)
    backend = params.get("select_crypto_backend", "auto")
    if backend == "cryptography":
        if account_key_passphrase != None:
            fail("account_key_passphrase is not supported with openssl backend")
        fail("cryptography backend is not supported in Starlark runtime")

    # Use openssl binary
    openssl_bin = "openssl"

    # Build command sequence for ACME interaction
    # For now, implement only directory retrieval via curl (no full ACME protocol)
    # Because Starlark has no networking, this module is incomplete without ctx.http_* — but ctx does not provide HTTP
    # Since ctx has NO HTTP client, we cannot implement real ACME inspection.
    # Instead: fail with clear message.
    fail("acme_inspect cannot be implemented in Starlark runtime because network requests (HTTP/HTTPS) are not supported")

    # Cleanup temp file (never reached due to fail above)
    if key_file != None and ctx.file_exists(key_file):
        # In real implementation, delete here
        pass
