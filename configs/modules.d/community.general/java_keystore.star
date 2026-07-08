def main(ctx, params):
    name = params["name"]
    password = params["password"]
    dest = params["dest"]
    force = params.get("force", False)
    certificate = params.get("certificate")
    certificate_path = params.get("certificate_path")
    private_key = params.get("private_key")
    private_key_path = params.get("private_key_path")
    private_key_passphrase = params.get("private_key_passphrase")
    keystore_type = params.get("keystore_type")
    ssl_backend = params.get("ssl_backend", "openssl")
    group = params.get("group")
    owner = params.get("owner")
    mode = params.get("mode")

    # Validate required parameters
    if certificate == None and certificate_path == None:
        fail("exactly one of 'certificate' or 'certificate_path' is required")
    if certificate != None and certificate_path != None:
        fail("only one of 'certificate' or 'certificate_path' can be specified")
    if private_key == None and private_key_path == None:
        fail("exactly one of 'private_key' or 'private_key_path' is required")
    if private_key != None and private_key_path != None:
        fail("only one of 'private_key' or 'private_key_path' can be specified")

    # Check keytool availability
    res = ctx.run(["which", "keytool"], mutates=False)
    if res.rc != 0:
        fail("keytool command not found in PATH")

    # Check openssl availability when using openssl backend
    if ssl_backend == "openssl":
        res = ctx.run(["which", "openssl"], mutates=False)
        if res.rc != 0:
            fail("openssl command not found in PATH")

    # Determine certificate and private key content
    cert_path = certificate_path if certificate_path != None else ""
    priv_key_path = private_key_path if private_key_path != None else ""

    # Handle certificate content via temporary file if provided inline
    if certificate != None:
        cert_fd = ctx.run(["mktemp"], mutates=False)
        if cert_fd.rc != 0:
            fail("failed to create temporary file for certificate")
        cert_path = cert_fd.stdout.strip()
        if cert_path == "":
            fail("empty temp path returned from mktemp")
        changed = ctx.file_write(cert_path, certificate)
        # Clean up later
        ctx.run(["rm", "-f", cert_path], mutates=False)

    # Handle private key content via temporary file if provided inline
    if private_key != None:
        priv_key_fd = ctx.run(["mktemp"], mutates=False)
        if priv_key_fd.rc != 0:
            fail("failed to create temporary file for private key")
        priv_key_path = priv_key_fd.stdout.strip()
        if priv_key_path == "":
            fail("empty temp path returned from mktemp")
        changed = ctx.file_write(priv_key_path, private_key)
        # Clean up later
        ctx.run(["rm", "-f", priv_key_path], mutates=False)

    # Check if keystore already exists
    keystore_exists = ctx.file_exists(dest)

    # Determine current keystore type if it exists
    current_type = None
    if keystore_exists:
        content = ctx.file_read(dest)
        if len(content) >= 4:
            if content[0] == chr(0xFE) and content[1] == chr(0xED) and content[2] == chr(0xFE) and content[3] == chr(0xED):
                current_type = "jks"
        if current_type == None:
            current_type = "pkcs12"

    # If force == True or keystore doesn't exist, we will recreate
    needs_recreate = force or not keystore_exists
    # If keystore exists and type mismatch, we need recreate
    if keystore_exists and keystore_type != None and keystore_type != current_type:
        needs_recreate = True

    # Check certificate fingerprint match if keystore exists and no force
    if keystore_exists and not needs_recreate:
        cert_cmd = ["openssl", "x509", "-noout", "-in", cert_path, "-fingerprint", "-sha256"]
        res = ctx.run(cert_cmd, mutates=False)
        if res.rc != 0:
            fail("failed to get fingerprint of provided certificate: " + res.stderr)
        fp_match = res.stdout.strip().split("=")
        current_fp = fp_match[-1].upper() if len(fp_match) > 1 else ""

        keytool_cmd = ["keytool", "-list", "-alias", name, "-keystore", dest, "-v"]
        res = ctx.run(keytool_cmd, mutates=False)
        if res.rc != 0:
            if ("Alias <" + name + "> does not exist") in res.stdout or ("does not exist") in res.stderr:
                needs_recreate = True
            elif ("password was incorrect") in res.stdout or ("Password is too short") in res.stdout:
                needs_recreate = True
            else:
                fail("keytool command failed: " + res.stderr)
        else:
            lines = res.stdout.split("\n")
            stored_fp = ""
            for line in lines:
                if line.strip().startswith("SHA256:"):
                    stored_fp = line.strip().replace("SHA256:", "").strip().upper()
                    break
            if stored_fp == "":
                fail("Unable to find stored certificate fingerprint in keytool output")
            if current_fp != stored_fp:
                needs_recreate = True

    # If we need to recreate or force, do it
    if needs_recreate:
        pkcs12_path = dest + ".tmp_pkcs12"
        ctx.run(["rm", "-f", pkcs12_path], mutates=False)

        openssl_cmd = ["openssl", "pkcs12", "-export", "-name", name, "-in", cert_path,
                       "-inkey", priv_key_path, "-out", pkcs12_path, "-passout", "stdin"]
        stdin_data = password + "\n"
        if private_key_passphrase != None:
            openssl_cmd.append("-passin")
            openssl_cmd.append("stdin")
            stdin_data = private_key_passphrase + "\n" + stdin_data

        res = ctx.run(openssl_cmd, mutates=False)
        if res.rc != 0:
            fail("openssl pkcs12 command failed: " + res.stderr)

        if keystore_type == "pkcs12":
            res = ctx.run(["mv", "-f", pkcs12_path, dest], mutates=True)
            if res.rc != 0:
                fail("failed to move pkcs12 file to destination: " + res.stderr)
        else:
            import_cmd = ["keytool", "-importkeystore", "-destkeystore", dest,
                          "-srckeystore", pkcs12_path, "-srcstoretype", "pkcs12",
                          "-alias", name, "-noprompt"]
            help_cmd = ["keytool", "-importkeystore", "-help"]
            help_res = ctx.run(help_cmd, mutates=False)
            if ("-deststoretype" in help_res.stdout or "-deststoretype" in help_res.stderr):
                import_cmd.insert(4, "-deststoretype")
                import_cmd.insert(5, "jks")

            stdin_data = password + "\n" + password + "\n" + password + "\n"
            res = ctx.run(import_cmd, mutates=False)
            if res.rc != 0:
                fail("keytool import command failed: " + res.stderr)

        ctx.run(["rm", "-f", pkcs12_path], mutates=False)

        if owner != None:
            ctx.run(["chown", owner, dest], mutates=True)
        if group != None:
            ctx.run(["chgrp", group, dest], mutates=True)
        if mode != None:
            ctx.run(["chmod", str(mode), dest], mutates=True)

        return {"changed": True, "msg": "Keystore created or updated"}

    # If no change, ensure file permissions are correct
    file_args = {"path": dest}
    if owner != None:
        file_args["owner"] = owner
    if group != None:
        file_args["group"] = group
    if mode != None:
        file_args["mode"] = mode

    current = ctx.stat(dest)
    if current == None:
        fail("keystore file disappeared")

    changed = False
    if owner != None and str(current.get("uid", "")) != str(owner):
        ctx.run(["chown", owner, dest], mutates=True)
        changed = True
    if group != None and str(current.get("gid", "")) != str(group):
        ctx.run(["chgrp", group, dest], mutates=True)
        changed = True
    if mode != None:
        current_mode = oct(current.get("mode", 0o0))[-3:]
        if str(current_mode) != str(mode)[-3:]:
            ctx.run(["chmod", str(mode), dest], mutates=True)
            changed = True

    if changed:
        return {"changed": True, "msg": "Keystore attributes updated"}
    return {"changed": False, "msg": "Keystore already exists with correct attributes"}
