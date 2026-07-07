def main(ctx, params):
    # Extract parameters
    action = params.get("action", "export")
    path = params["path"]
    force = params.get("force", False)
    state = params.get("state", "present")
    src = params.get("src")
    backup_flag = params.get("backup", False)
    return_content = params.get("return_content", False)
    friendly_name = params.get("friendly_name")
    passphrase = params.get("passphrase", "")
    privatekey_passphrase = params.get("privatekey_passphrase", "")
    privatekey_path = params.get("privatekey_path")
    privatekey_content = params.get("privatekey_content")
    certificate_path = params.get("certificate_path")
    other_certificates = params.get("other_certificates", [])
    other_certificates_parse_all = params.get("other_certificates_parse_all", False)
    mode = params.get("mode")

    # Check mode
    in_check_mode = ctx.check_mode

    # Handle absent state
    if state == "absent":
        exists = ctx.file_exists(path)
        if exists:
            if in_check_mode:
                return {"changed": True, "msg": "would remove " + path}
            else:
                if backup_flag:
                    # Create backup
                    backup_path = path + "." + str(ctx.facts().get("hostname", "host")) + ".bak"
                    content = ctx.file_read(path)
                    ctx.file_write(backup_path, content)
                ctx.run(["rm", "-f", path], mutates=True)
                return {"changed": True, "msg": "removed " + path}
        else:
            return {"changed": False, "msg": path + " does not exist"}

    # Handle present state
    if state == "present":
        if action == "parse":
            if src == None:
                fail("src is required for action=parse")
            # Parse action: read PKCS#12 and extract to PEM
            if in_check_mode:
                return {"changed": True, "msg": "would parse " + src + " to " + path}
            # For simplicity, use openssl command for parsing (assuming openssl installed)
            res = ctx.run([
                "openssl", "pkcs12", "-in", src, "-out", path,
                "-passin", "pass:" + passphrase if passphrase else "none"
            ], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would parse " + src + " to " + path}
            if res.rc != 0:
                fail("failed to parse PKCS#12: " + res.stderr)
            changed = True
            if return_content:
                content = ctx.file_read(path)
                return {"changed": changed, "msg": "parsed " + src + " to " + path, "data": {"pkcs12": content}}
            return {"changed": changed, "msg": "parsed " + src + " to " + path}

        if action == "export":
            # Export action: generate PKCS#12
            if not force and ctx.file_exists(path):
                # Check idempotency: compare current vs desired content
                # Since PKCS#12 encryption is not deterministic (uses random salt),
                # strict idempotency is not feasible. We rely on force flag only.
                pass  # allow existing file if force=False; user must use force=True to re-generate

            if in_check_mode:
                return {"changed": True, "msg": "would export PKCS#12 to " + path}

            # Prepare inputs: read private key and certificate
            if privatekey_path != None:
                if ctx.file_exists(privatekey_path):
                    privatekey_content = ctx.file_read(privatekey_path)
                else:
                    fail("privatekey_path does not exist: " + privatekey_path)
            elif privatekey_content == None:
                fail("privatekey_path or privatekey_content is required")

            if certificate_path != None:
                if not ctx.file_exists(certificate_path):
                    fail("certificate_path does not exist: " + certificate_path)
                cert_content = ctx.file_read(certificate_path)
            else:
                cert_content = None

            # Read other_certificates if needed
            ca_certs_content = []
            if other_certificates:
                for cert_path in other_certificates:
                    if not ctx.file_exists(cert_path):
                        fail("other_certificates path does not exist: " + cert_path)
                    ca_certs_content.append(ctx.file_read(cert_path))

            # Use openssl command to generate PKCS#12
            # Note: This is a best-effort translation; encryption_level, iter_size, etc. are ignored for idempotency
            cmd = ["openssl", "pkcs12", "-export", "-out", path, "-inkey", "/dev/stdin"]
            if friendly_name:
                cmd.extend(["-name", friendly_name])
            if passphrase:
                cmd.extend(["-passout", "pass:" + passphrase])
            if cert_content:
                cmd.extend(["-certfile", "/dev/stdin"])
            if ca_certs_content:
                cmd.extend(["-certfile", "/dev/stdin"])

            if in_check_mode:
                return {"changed": True, "msg": "would export PKCS#12 to " + path}

            # Execute command with stdin input
            stdin_data = privatekey_content
            if cert_content:
                stdin_data += "\n" + cert_content
            for ca_cert in ca_certs_content:
                stdin_data += "\n" + ca_cert

            # Write stdin to temp file to use with openssl (since ctx.run does not support stdin)
            tmp_path = path + ".tmp"
            ctx.file_write(tmp_path, stdin_data)

            # Run openssl command
            res = ctx.run([
                "openssl", "pkcs12", "-export", "-out", path, "-inkey", tmp_path,
                "-passin", "pass:" + (privatekey_passphrase if privatekey_passphrase else ""),
                "-passout", "pass:" + (passphrase if passphrase else "")
            ], mutates=True)
            # Clean up temp file
            ctx.run(["rm", "-f", tmp_path], mutates=True)

            if res.skipped:
                return {"changed": True, "msg": "would export PKCS#12 to " + path}
            if res.rc != 0:
                fail("failed to export PKCS#12: " + res.stderr)

            # Set file attributes
            if mode == None:
                mode = "0400"
            ctx.run(["chmod", mode, path], mutates=True)
            if backup_flag:
                backup_path = path + "." + str(ctx.facts().get("hostname", "host")) + ".bak"
                content = ctx.file_read(path)
                ctx.file_write(backup_path, content)

            if return_content:
                content = ctx.file_read(path)
                return {"changed": True, "msg": "exported PKCS#12 to " + path, "data": {"pkcs12": content}}
            return {"changed": True, "msg": "exported PKCS#12 to " + path}

    fail("unsupported state or action")
