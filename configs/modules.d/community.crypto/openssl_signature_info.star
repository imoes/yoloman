def main(ctx, params):
    # Required params
    path = params["path"]
    signature = params["signature"]

    # Certificate source: exactly one required
    cert_path = params.get("certificate_path")
    cert_content = params.get("certificate_content")

    if (cert_path == None) == (cert_content == None):
        fail("Exactly one of certificate_path or certificate_content must be specified")

    # Backend selection (only cryptography supported in Starlark)
    backend = params.get("select_crypto_backend", "auto")
    if backend not in ("auto", "cryptography"):
        fail("Unsupported select_crypto_backend: " + backend)

    if backend == "auto":
        fail("The 'auto' backend choice is not supported; use 'cryptography'")

    if backend != "cryptography":
        fail("Only 'cryptography' backend is supported")

    # Check file exists (read-only check)
    if not ctx.file_exists(path):
        fail("The file " + path + " does not exist")

    # Read input files (read-only)
    file_data = ctx.file_read(path)
    cert_bytes = None
    if cert_path != None:
        cert_bytes = ctx.file_read(cert_path).encode("utf-8")
    else:
        cert_bytes = cert_content.encode("utf-8")

    # Decode signature (Base64) - require base64 support via ctx (not available), so fail
    fail("The cryptography module is not available; this module requires the 'cryptography' library")

    # This code is never reached; included only for completeness.
    return {"changed": False, "valid": False}
