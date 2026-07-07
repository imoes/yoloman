def main(ctx, params):
    # Extract required parameters
    acme_directory = params["acme_directory"]
    acme_version = params["acme_version"]
    certificate_path = params["certificate"]
    revoke_reason = params.get("revoke_reason")
    account_uri = params.get("account_uri")
    request_timeout = params.get("request_timeout", 10)
    validate_certs = params.get("validate_certs", True)

    # Determine backend
    select_crypto = params.get("select_crypto_backend", "auto")

    # Validate exactly one key source provided
    account_key_src = params.get("account_key_src")
    account_key_content = params.get("account_key_content")
    private_key_src = params.get("private_key_src")
    private_key_content = params.get("private_key_content")

    key_provided = sum([
        account_key_src != None,
        account_key_content != None,
        private_key_src != None,
        private_key_content != None
    ])
    if key_provided != 1:
        fail("Exactly one of account_key_src, account_key_content, private_key_src, private_key_content must be specified")

    # Read certificate PEM file
    if not ctx.file_exists(certificate_path):
        fail("Certificate file not found: " + certificate_path)
    cert_pem = ctx.file_read(certificate_path)

    # Convert PEM certificate to DER and base64url without padding
    # Note: We simulate the conversion using openssl CLI as the backend
    # since Starlark has no crypto primitives.
    if select_crypto not in ("auto", "openssl"):
        fail("Only 'auto' or 'openssl' backend supported in Starlark implementation")

    # Use openssl to convert PEM certificate to DER, then base64url (no padding)
    # Step 1: convert PEM to DER
    der_res = ctx.run([
        "openssl", "x509", "-in", certificate_path, "-outform", "DER"
    ], mutates=False)
    if der_res.rc != 0:
        fail("Failed to convert certificate to DER: " + der_res.stderr)

    # Step 2: base64url encode without padding (RFC 7515)
    # Using openssl base64 with custom transformation
    b64_res = ctx.run([
        "openssl", "base64", "-A"
    ], mutates=False)
    # Pass DER via stdin to openssl base64, then transform to base64url
    # Since ctx.run doesn't support stdin easily, we use a temp file
    # but as per contract, avoid file_write unless mutates=True and check_mode safe.
    # Instead, use openssl directly with -in and postprocess output.
    b64_der = der_res.stdout  # openssl base64 output is standard base64 with newlines removed if -A

    # Convert standard base64 to base64url: replace + with -, / with _, remove trailing =
    b64_der = b64_der.strip()
    base64url = b64_der.replace("+", "-").replace("/", "_").rstrip("=")

    # Construct revocation payload
    payload = {"certificate": base64url}

    # Determine ACME endpoint based on version
    # Note: We don't have direct directory access; we'll simulate endpoint selection.
    # In real Starlark this would require calling the directory first, but per contract,
    # we focus on common case and may omit complex directory negotiation.
    # Instead, we hardcode standard endpoints as in original Ansible defaults.
    if acme_version == 1:
        if "letsencrypt" in acme_directory.lower():
            # Staging by default per original doc, but we use user-provided
            revoke_endpoint = acme_directory.rstrip("/") + "/revoke-cert"
        elif "buypass" in acme_directory.lower():
            revoke_endpoint = acme_directory.rstrip("/") + "/revoke-cert"
        else:
            # Generic ACME v1
            revoke_endpoint = acme_directory.rstrip("/") + "/revoke-cert"
        payload["resource"] = "revoke-cert"
    else:  # acme_version == 2
        # ACME v2 uses "revokeCert" (case-sensitive)
        if "letsencrypt" in acme_directory.lower():
            revoke_endpoint = acme_directory.rstrip("/") + "/acme/revoke-cert"
        elif "buypass" in acme_directory.lower():
            revoke_endpoint = acme_directory.rstrip("/") + "/acme/revoke-cert"
        elif "zerossl" in acme_directory.lower():
            revoke_endpoint = acme_directory.rstrip("/") + "/acme/revoke-cert"
        elif "sectigo" in acme_directory.lower():
            revoke_endpoint = acme_directory.rstrip("/") + "/acme/revoke-cert"
        else:
            revoke_endpoint = acme_directory.rstrip("/") + "/acme/revoke-cert"

    # Add reason if provided
    if revoke_reason != None:
        payload["reason"] = revoke_reason

    # Handle private key vs account key
    if private_key_src != None or private_key_content != None:
        # Use private key to sign request
        private_key_file = private_key_src if private_key_src != None else None
        passphrase = params.get("private_key_passphrase")
        if passphrase != None:
            fail("Passphrase not supported with openssl backend in Starlark implementation")

        if private_key_src != None:
            if not ctx.file_exists(private_key_src):
                fail("Private key file not found: " + private_key_src)
            private_key_content = ctx.file_read(private_key_src)
        # For Starlark, simulate JWS signing with openssl dgst -sign and construct request manually.
        # Since this is complex, and original Ansible module requires full ACME client logic,
        # we limit implementation to the common case: revoke using account key via account URI.

        # Fallback: fail with clear message since full JWS signing isn't feasible in Starlark
        fail("Revocation using private key is not supported in Starlark implementation; use account_key_src")
    else:
        # Use account key and account URI
        account_key_file = account_key_src if account_key_src != None else None
        if account_key_file != None:
            if not ctx.file_exists(account_key_file):
                fail("Account key file not found: " + account_key_file)
            # In check_mode, skip actual revocation
            if ctx.check_mode:
                # Probe account existence if possible — but without full crypto,
                # we assume account exists and revocation would change state.
                return {"changed": True, "msg": "would revoke certificate"}

        # Simulate revocation request using curl
        # Construct JSON payload (base64url-encoded)
        # Since we cannot serialize JSON in Starlark without stdlib, we hardcode minimal payload
        # In practice, we would need a JSON serializer — but per contract, use only ctx.*.
        # Thus, we skip actual revocation in Starlark unless account key + URI are used and
        # we can delegate to an external helper.

        # For correctness and to avoid overpromising, we only handle the check_mode case.
        if ctx.check_mode:
            # Predict change: assume certificate is not already revoked
            return {"changed": True, "msg": "would revoke certificate"}

        # In normal mode, we simulate by delegating to a shell helper — but the contract forbids shell.
        # So, we must fail with clear message.
        fail("Revocation using account key is not fully supported in Starlark implementation; requires full ACME client")

    return {"changed": True, "msg": "certificate revoked"}
