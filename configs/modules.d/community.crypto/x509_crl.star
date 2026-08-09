def main(ctx, params):
    # Extract key parameters
    path = params["path"]
    state = params.get("state", "present")
    crl_mode = params.get("crl_mode") or params.get("mode", "generate")  # mode deprecated
    force = params.get("force", False)
    backup = params.get("backup", False)
    format_opt = params.get("format", "pem")
    digest = params.get("digest", "sha256")
    last_update = params.get("last_update", "+0s")
    next_update = params.get("next_update")
    ignore_timestamps = params.get("ignore_timestamps", False)
    return_content = params.get("return_content", False)

    # Required for state=present
    issuer = params.get("issuer")
    issuer_ordered = params.get("issuer_ordered")
    revoked = params.get("revoked_certificates") or []
    privatekey_path = params.get("privatekey_path")
    privatekey_content = params.get("privatekey_content")
    privatekey_passphrase = params.get("privatekey_passphrase")

    # Validation: mutual exclusion and required parameters
    if state == "present":
        if privatekey_path and privatekey_content:
            fail("privatekey_path and privatekey_content are mutually exclusive")
        if not (privatekey_path or privatekey_content):
            fail("one of privatekey_path or privatekey_content is required")
        if issuer and issuer_ordered:
            fail("issuer and issuer_ordered are mutually exclusive")
        if not issuer and not issuer_ordered:
            fail("one of issuer or issuer_ordered is required")
        if not next_update:
            fail("next_update is required when state=present")
        if not revoked:
            fail("revoked_certificates is required when state=present")

    # Check if CRL file exists
    exists = ctx.file_exists(path)
    if not exists and state == "absent":
        return {"changed": False, "msg": "CRL file does not exist"}

    # Read existing CRL if present
    crl_content = None
    actual_format = None
    if exists and state == "present":
        crl_content = ctx.file_read(path)
        # Detect format by content prefix
        actual_format = "pem" if crl_content.startswith("-----BEGIN X509 CRL-----") else "der"

    # In check_mode, predict change
    if ctx.check_mode:
        changed = False
        if state == "absent":
            changed = exists
        elif state == "present":
            # Heuristic: changed if not exists, force, format differs, or timestamps differ
            if not exists or force:
                changed = True
            elif format_opt != actual_format:
                changed = True
            # For simplicity, assume timestamps differ if not ignored
            elif not ignore_timestamps:
                changed = True
            # Assume content differs unless exact match (simplified)
            elif crl_content and crl_mode == "generate":
                changed = True
        msg = "would generate" if state == "present" else "would remove"
        return {"changed": changed, "msg": msg}

    # Action: remove
    if state == "absent":
        if exists:
            # Backup
            if backup:
                # Create backup via run (fallback since no built-in backup)
                backup_path = path + ".bak"
                ctx.run(["cp", "-p", path, backup_path], mutates=True)
            # Remove file
            ctx.run(["rm", "-f", path], mutates=True)
            return {"changed": True, "msg": "CRL removed"}
        return {"changed": False, "msg": "CRL already absent"}

    # Action: generate/update CRL (state == "present")
    # Build command to generate CRL using openssl
    cmd = ["openssl", "ca", "-gencrl"]
    if crl_mode == "update" and exists:
        cmd.append("-update")
    cmd.extend(["-out", path, "-cert", "/tmp/ca.crt"])  # placeholder for CA cert
    if digest and digest != "sha256":
        cmd.extend(["-digest", digest])
    if privatekey_path:
        cmd.extend(["-keyfile", privatekey_path])
    if privatekey_passphrase:
        cmd.extend(["-passin", "pass:" + privatekey_passphrase])
    if privatekey_content:
        # Write private key content to temp file
        key_path = "/tmp/ca.key"
        ctx.file_write(key_path, privatekey_content, mode="0600")
        cmd.extend(["-keyfile", key_path])

    # In check_mode, skip actual command (already handled above)
    if ctx.check_mode:
        return {"changed": True, "msg": "would generate CRL"}

    # Execute command
    res = ctx.run(cmd, mutates=True, ok_codes=[0])
    if res.rc != 0:
        fail("failed to generate CRL: " + res.stderr)

    # Convert format if necessary (PEM to DER or vice versa)
    if format_opt != actual_format:
        if format_opt == "der":
            convert_cmd = ["openssl", "crl", "-in", path, "-outform", "DER", "-out", path]
        else:
            convert_cmd = ["openssl", "crl", "-in", path, "-outform", "PEM", "-out", path]
        res = ctx.run(convert_cmd, mutates=True, ok_codes=[0])
        if res.rc != 0:
            fail("failed to convert CRL format: " + res.stderr)

    # Set file attributes (owner, group, mode)
    file_args = {}
    if params.get("owner"):
        file_args["owner"] = params["owner"]
    if params.get("group"):
        file_args["group"] = params["group"]
    if params.get("mode"):
        file_args["mode"] = params["mode"]
    if file_args:
        # Simulate chown/chmod via run (no direct file attribute support in ctx)
        if "owner" in file_args or "group" in file_args:
            owner = file_args.get("owner", "")
            group = file_args.get("group", "")
            owner_str = owner + (":" + group if group else "")
            ctx.run(["chown", owner_str, path], mutates=True, ok_codes=[0])
        if "mode" in file_args:
            ctx.run(["chmod", file_args["mode"], path], mutates=True, ok_codes=[0])

    # Return content if requested
    if return_content:
        crl_content = ctx.file_read(path)
    else:
        crl_content = None

    # Backup if requested
    if backup:
        backup_path = path + ".bak"
        ctx.run(["cp", "-p", path, backup_path], mutates=True)

    return {
        "changed": True,
        "msg": "CRL generated",
        "filename": path,
        "format": format_opt,
        "crl": crl_content,
    }
