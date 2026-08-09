def main(ctx, params):
    # Extract parameters
    content = params.get("content")
    privatekey_path = params.get("privatekey_path")
    privatekey_content = params.get("privatekey_content")

    # Validation: exactly one of privatekey_path or privatekey_content must be specified
    if privatekey_path == None and privatekey_content == None:
        fail("Either privatekey_path or privatekey_content must be specified")
    if privatekey_path != None and privatekey_content != None:
        fail("Only one of privatekey_path or privatekey_content can be specified")

    # Determine if we have existing CSR content to compare
    existing_csr = None
    if content != None:
        existing_csr = content.strip()

    # Use openssl command to generate CSR
    # Build command list for openssl req -new
    cmd = ["openssl", "req", "-new"]

    # Add private key source
    if privatekey_path != None:
        cmd.extend(["-key", privatekey_path])
    else:
        # Write private key content to a temporary file using ctx.file_write
        tmp_key_path = "/tmp/private_key_" + str(hash(ctx)) + ".pem"
        changed = ctx.file_write(tmp_key_path, privatekey_content, mode="0600")
        cmd.extend(["-key", tmp_key_path])

    # Add subject fields
    if params.get("common_name"):
        cmd.extend(["-subj", "/CN=" + params["common_name"]])
    else:
        # Build subject from components if CN not provided
        subject_parts = []
        for field, option in [
            ("country_name", "C"),
            ("state_or_province_name", "ST"),
            ("locality_name", "L"),
            ("organization_name", "O"),
            ("organizational_unit_name", "OU"),
            ("email_address", "emailAddress"),
        ]:
            value = params.get(field)
            if value:
                subject_parts.append(option + "=" + value)
        if subject_parts:
            cmd.extend(["-subj", "/" + "/".join(subject_parts)])
        else:
            fail("common_name or at least one subject field must be specified")

    # Add extensions if needed (basic_constraints, key_usage, etc.)
    # For simplicity, only handle the most common CSR options
    # Additional options require complex parsing and should fail for unsupported ones
    extensions_map = {
        "basic_constraints": "basicConstraints",
        "key_usage": "keyUsage",
        "extended_key_usage": "extendedKeyUsage",
    }
    extensions_cmd = []
    for ansible_opt, openssl_opt in extensions_map.items():
        if params.get(ansible_opt):
            extensions_cmd.append(openssl_opt + "=" + ",".join(params[ansible_opt]))
    if extensions_cmd:
        # Use config file approach for complex extensions (not implemented here)
        fail("Extended CSR options (basic_constraints, key_usage, etc.) are not yet supported in starlark")

    # Execute command
    if ctx.check_mode:
        # In check_mode, we need to detect if CSR would change
        # For simplicity, we assume change if no existing CSR matches expectations
        # Check existing CSR against expected values
        if existing_csr != None:
            # Try to extract subject from existing CSR
            res = ctx.run(
                ["openssl", "req", "-in", "/dev/stdin", "-noout", "-subject"],
                mutates=False,
            )
            res = ctx.run(
                ["openssl", "req", "-in", "/dev/stdin", "-noout", "-subject"],
                mutates=False,
            )
            # Compare subjects (simplified)
            expected_subj = ""
            if params.get("common_name"):
                expected_subj = "/CN=" + params["common_name"]
            else:
                parts = []
                if params.get("country_name"):
                    parts.append("C=" + params["country_name"])
                if params.get("state_or_province_name"):
                    parts.append("ST=" + params["state_or_province_name"])
                if params.get("locality_name"):
                    parts.append("L=" + params["locality_name"])
                if params.get("organization_name"):
                    parts.append("O=" + params["organization_name"])
                if params.get("organizational_unit_name"):
                    parts.append("OU=" + params["organizational_unit_name"])
                if params.get("email_address"):
                    parts.append("emailAddress=" + params["email_address"])
                expected_subj = "/" + "/".join(parts) if parts else ""
            if expected_subj and expected_subj in existing_csr:
                return {"changed": False, "msg": "CSR already matches requirements", "csr": existing_csr}

        # Predict that change would occur
        return {"changed": True, "msg": "would generate new CSR"}

    # Generate CSR: pipe CSR to stdout
    res = ctx.run(cmd, mutates=True)

    # Clean up temporary key file if needed
    if privatekey_content != None and ctx.file_exists(tmp_key_path):
        ctx.run(["rm", "-f", tmp_key_path], mutates=True)

    if res.rc != 0:
        fail("Failed to generate CSR: " + res.stderr)

    # Extract CSR content from stdout
    csr_content = res.stdout.strip()
    if not csr_content:
        fail("Empty CSR output from openssl")

    return {
        "changed": True,
        "msg": "CSR generated successfully",
        "csr": csr_content,
        "subject": [["CN", params["common_name"]]] if params.get("common_name") else [],
        "privatekey": privatekey_path if privatekey_path != None else None,
    }
