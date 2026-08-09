def main(ctx, params):
    # Required params validation
    if "keystore_path" not in params:
        fail("keystore_path is required")
    if "keystore_pass" not in params:
        fail("keystore_pass is required")
    if "cert_alias" not in params or params["cert_alias"] == None:
        fail("cert_alias is required")

    # State handling
    state = params.get("state", "present")
    if state != "present" and state != "absent":
        fail("state must be 'present' or 'absent'")

    # Certificate source validation
    cert_url = params.get("cert_url")
    cert_path = params.get("cert_path")
    pkcs12_path = params.get("pkcs12_path")
    sources = [bool(cert_url), bool(cert_path), bool(pkcs12_path)]
    if state == "present" and sum(sources) != 1:
        fail("Exactly one of cert_url, cert_path, or pkcs12_path is required for state=present")

    # Optional defaults
    cert_port = params.get("cert_port", 443)
    executable = params.get("executable", "keytool")
    keystore_create = params.get("keystore_create", False)
    keystore_type = params.get("keystore_type")
    trust_cacert = params.get("trust_cacert", False)
    pkcs12_alias = params.get("pkcs12_alias", "1")
    pkcs12_password = params.get("pkcs12_password", "")
    cert_alias = params["cert_alias"]

    keystore_path = params["keystore_path"]

    # Check if keytool exists
    res = ctx.run([executable], ok_codes=[1])  # keytool without args returns rc=1
    if res.rc != 1:
        fail("keytool executable not found or not accessible")

    # Check keystore existence
    if keystore_create == False and ctx.file_exists(keystore_path) == False:
        fail("Module requires existing keystore at keystore_path '" + keystore_path + "'")

    # Helper: build command args list
    def build_cmd(base_args):
        cmd = [executable] + base_args
        if keystore_type:
            cmd += ["-storetype", keystore_type]
        return cmd

    # Helper: check cert presence
    def check_cert_present():
        check_cmd = build_cmd([
            "-list",
            "-keystore", keystore_path,
            "-alias", cert_alias,
            "-rfc"
        ])
        res = ctx.run(check_cmd, mutates=False, ok_codes=[0, 1])
        return (res.rc == 0, res.stdout)

    # Helper: download cert from URL
    def download_cert_from_url(url, port):
        fetch_cmd = [executable, "-printcert", "-rfc", "-sslserver", url + ":" + str(port)]
        res = ctx.run(fetch_cmd, mutates=False, ok_codes=[0])
        if res.rc != 0:
            fail("Cannot download certificate from " + url + ":" + str(port) + ": " + res.stderr)
        return res.stdout

    # Helper: get sha256 digest of PEM cert string using keytool -printcert output
    def get_digest_from_pem(pem_content):
        # Write to temp file via ctx
        tmpfile = "/tmp/java_cert_digest_" + cert_alias.replace("/", "_") + ".pem"
        ctx.file_write(tmpfile, pem_content)
        # Use keytool to extract fingerprint
        fp_cmd = [executable, "-printcert", "-file", tmpfile]
        res = ctx.run(fp_cmd, mutates=False, ok_codes=[0])
        if res.rc != 0:
            fail("Cannot compute digest from certificate: " + res.stderr)
        # Parse SHA256 fingerprint line from output (e.g., "SHA256: AB:CD:...")
        for line in res.stdout.split("\n"):
            if "SHA256:" in line:
                fp = line.split("SHA256:")[1].strip()
                # Normalize fingerprint (remove colons and lowercase)
                return fp.replace(":", "").lower()
        fail("Could not parse SHA256 fingerprint from keytool output")

    # Helper: extract cert from pkcs12
    def export_pkcs12_cert(pkcs12_path, pkcs12_alias, pkcs12_pass):
        export_cmd = build_cmd([
            "-list",
            "-noprompt",
            "-srckeystore", pkcs12_path,
            "-srcalias", pkcs12_alias,
            "-storetype", "pkcs12",
            "-rfc"
        ])
        res = ctx.run(export_cmd, data=pkcs12_pass + "\n", mutates=False, ok_codes=[0])
        if res.rc != 0:
            fail("Cannot extract certificate from PKCS12: " + res.stderr)
        return res.stdout

    # Check current cert presence
    alias_exists, alias_output = check_cert_present()

    # === ABSENT STATE ===
    if state == "absent":
        if alias_exists == True:
            if ctx.check_mode == True:
                return {"changed": True, "msg": "would delete certificate alias '" + cert_alias + "' from keystore"}
            del_cmd = build_cmd([
                "-delete",
                "-noprompt",
                "-keystore", keystore_path,
                "-alias", cert_alias
            ])
            res = ctx.run(del_cmd, data=params["keystore_pass"], mutates=True, ok_codes=[0])
            if res.rc != 0:
                fail("Failed to delete certificate alias '" + cert_alias + "': " + res.stderr)
            return {"changed": True, "msg": "deleted certificate alias '" + cert_alias + "' from keystore"}
        else:
            return {"changed": False, "msg": "certificate alias '" + cert_alias + "' not found"}

    # === PRESENT STATE ===
    # Determine current certificate digest if alias exists
    current_digest = ""
    if alias_exists == True:
        current_digest = get_digest_from_pem(alias_output)

    # Get new certificate content
    if pkcs12_path != None:
        new_cert_content = export_pkcs12_cert(pkcs12_path, pkcs12_alias, pkcs12_password)
    elif cert_path != None:
        # Read local file
        if ctx.file_exists(cert_path) == False:
            fail("Certificate file '" + cert_path + "' not found")
        new_cert_content = ctx.file_read(cert_path)
    elif cert_url != None:
        new_cert_content = download_cert_from_url(cert_url, cert_port)
    else:
        fail("No certificate source provided")

    # Compute new cert digest
    new_digest = get_digest_from_pem(new_cert_content)

    # Compare digests
    if current_digest == new_digest:
        return {"changed": False, "msg": "certificate alias '" + cert_alias + "' already present with identical content"}

    # Change needed
    if ctx.check_mode == True:
        return {"changed": True, "msg": "would update certificate alias '" + cert_alias + "' in keystore"}

    # If alias exists, delete first
    if alias_exists == True:
        del_cmd = build_cmd([
            "-delete",
            "-noprompt",
            "-keystore", keystore_path,
            "-alias", cert_alias
        ])
        res = ctx.run(del_cmd, data=params["keystore_pass"], mutates=True, ok_codes=[0])
        if res.rc != 0:
            fail("Failed to delete existing certificate alias '" + cert_alias + "': " + res.stderr)

    # Import new certificate
    if pkcs12_path != None:
        import_cmd = build_cmd([
            "-importkeystore",
            "-noprompt",
            "-srcstoretype", "pkcs12",
            "-srckeystore", pkcs12_path,
            "-srcalias", pkcs12_alias,
            "-destkeystore", keystore_path,
            "-destalias", cert_alias
        ])
        # For new keystore, password entered twice
        if ctx.file_exists(keystore_path) == False:
            secret_data = params["keystore_pass"] + "\n" + params["keystore_pass"] + "\n" + pkcs12_password + "\n"
        else:
            secret_data = params["keystore_pass"] + "\n" + pkcs12_password + "\n"
        res = ctx.run(import_cmd, data=secret_data, mutates=True, ok_codes=[0])
    else:
        # Write cert to temp file
        tmpfile = "/tmp/java_cert_import_" + cert_alias.replace("/", "_") + ".pem"
        ctx.file_write(tmpfile, new_cert_content)
        import_cmd = build_cmd([
            "-importcert",
            "-noprompt",
            "-keystore", keystore_path,
            "-file", tmpfile,
            "-alias", cert_alias
        ])
        if trust_cacert == True:
            import_cmd += ["-trustcacerts"]
        # Password entered twice for import
        res = ctx.run(import_cmd, data=params["keystore_pass"] + "\n" + params["keystore_pass"] + "\n", mutates=True, ok_codes=[0])
        # Cleanup temp file
        ctx.run(["rm", "-f", tmpfile], mutates=True, ok_codes=[0])

    if res.rc != 0:
        fail("Failed to import certificate alias '" + cert_alias + "': " + res.stderr)

    return {"changed": True, "msg": "imported certificate alias '" + cert_alias + "' into keystore"}
