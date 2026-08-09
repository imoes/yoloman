def main(ctx, params):
    provider = params["provider"]
    content = params.get("content")
    force = params.get("force", False)
    ignore_timestamps = params.get("ignore_timestamps", True)

    # Only selfsigned provider is supported in this translation
    if provider != "selfsigned":
        ctx.fail("only 'selfsigned' provider is supported")

    # Read CSR content if csr_content is provided
    csr_content = params.get("csr_content")
    if csr_content == None:
        csr_path = params.get("csr_path")
        if csr_path == None:
            ctx.fail("either csr_content or csr_path must be provided")
        if not ctx.file_exists(csr_path):
            ctx.fail("CSR file does not exist: " + csr_path)
        csr_content = ctx.file_read(csr_path)

    # Read private key if privatekey_content is provided, otherwise read from path
    privatekey_content = params.get("privatekey_content")
    if privatekey_content == None:
        privatekey_path = params.get("privatekey_path")
        if privatekey_path == None:
            ctx.fail("either privatekey_content or privatekey_path must be provided")
        if not ctx.file_exists(privatekey_path):
            ctx.fail("private key file does not exist: " + privatekey_path)
        privatekey_content = ctx.file_read(privatekey_path)

    # Check if certificate already exists and is valid
    certificate_exists = content != None and len(content.strip()) > 0
    if force == False and certificate_exists:
        # Validate the existing certificate against CSR and key using openssl
        check_cmd = [
            "openssl",
            "verify",
            "-CAfile",
            "/dev/null",
            "-partial_chain",
            "-verify_return_error"
        ]
        # Create a temporary file for the certificate
        tmp_cert = ctx.run(
            ["mktemp", "/tmp/cert.XXXXXX"],
            mutates=False
        )
        if tmp_cert.rc != 0:
            ctx.fail("failed to create temp file for certificate")
        cert_path = tmp_cert.stdout.strip()
        # Write content to temp file
        ctx.file_write(cert_path, content, mode="0600")
        # Check if certificate matches CSR
        verify_cmd = ["openssl", "x509", "-noout", "-modulus", "-in", cert_path]
        verify_res = ctx.run(verify_cmd, mutates=False)
        if verify_res.rc != 0:
            ctx.run(["rm", "-f", cert_path])
            ctx.fail("failed to read certificate modulus: " + verify_res.stderr)
        cert_modulus = verify_res.stdout.strip()
        # Get CSR modulus
        csr_verify_cmd = ["openssl", "req", "-noout", "-modulus", "-in", "/dev/stdin"]
        csr_verify_res = ctx.run(
            csr_verify_cmd + ["<", csr_content],
            mutates=False
        )
        if csr_verify_res.rc != 0:
            ctx.run(["rm", "-f", cert_path])
            ctx.fail("failed to read CSR modulus: " + csr_verify_res.stderr)
        csr_modulus = csr_verify_res.stdout.strip()
        ctx.run(["rm", "-f", cert_path])
        if cert_modulus == csr_modulus:
            return {"changed": False, "msg": "Certificate already exists and is valid", "certificate": content}

    # Generate new certificate using openssl
    if ctx.check_mode:
        return {"changed": True, "msg": "would generate certificate", "certificate": ""}

    # Create temp files for key and CSR
    tmp_key = ctx.run(["mktemp", "/tmp/key.XXXXXX"], mutates=False)
    if tmp_key.rc != 0:
        ctx.fail("failed to create temp file for key")
    key_path = tmp_key.stdout.strip()
    tmp_csr = ctx.run(["mktemp", "/tmp/csr.XXXXXX"], mutates=False)
    if tmp_csr.rc != 0:
        ctx.run(["rm", "-f", key_path])
        ctx.fail("failed to create temp file for CSR")
    csr_path = tmp_csr.stdout.strip()

    # Write key and CSR to temp files
    ctx.file_write(key_path, privatekey_content, mode="0600")
    ctx.file_write(csr_path, csr_content, mode="0600")

    # Generate self-signed certificate
    gen_cmd = [
        "openssl", "x509",
        "-req",
        "-in", csr_path,
        "-signkey", key_path,
        "-out", "/dev/stdout",
        "-days", "365",
        "-sha256"
    ]
    if "subject" in params:
        gen_cmd.extend(["-subj", params["subject"]])
    if "not_before" in params:
        gen_cmd.extend(["-startdate", params["not_before"]])
    if "not_after" in params:
        gen_cmd.extend(["-enddate", params["not_after"]])

    gen_res = ctx.run(gen_cmd, mutates=True)
    ctx.run(["rm", "-f", key_path, csr_path])

    if gen_res.rc != 0:
        ctx.fail("failed to generate certificate: " + gen_res.stderr)

    certificate = gen_res.stdout
    return {"changed": True, "msg": "Certificate generated successfully", "certificate": certificate}
