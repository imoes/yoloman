def main(ctx, params):
    path = params.get("path")
    content = params.get("content")
    passphrase = params.get("passphrase")
    check_consistency = params.get("check_consistency", False)
    select_crypto_backend = params.get("select_crypto_backend", "auto")

    if (path == None) == (content == None):
        fail("exactly one of 'path' or 'content' must be specified")

    # Determine backend (only 'auto' and 'cryptography' supported)
    if select_crypto_backend not in ["auto", "cryptography"]:
        fail("unsupported select_crypto_backend: " + select_crypto_backend)

    # Read key data
    if content != None:
        data = content
    else:
        if not ctx.file_exists(path):
            fail("private key file not found: " + path)
        data = ctx.file_read(path)

    # Use openssl cli to extract key info (no external Python deps)
    openssl_args = ["openssl", "rsa", "-in", "/dev/stdin", "-pubout", "-noout"]

    if passphrase != None:
        openssl_args = ["openssl", "rsa", "-in", "/dev/stdin", "-pubout", "-noout", "-passin", "pass:" + passphrase]

    # Try to validate key with openssl (load and parse check)
    res = ctx.run(openssl_args + ["-text", "-noout"], mutates=False)
    if res.rc != 0:
        # Try with EC keys (fallback)
        openssl_args = ["openssl", "ec", "-in", "/dev/stdin", "-pubout", "-noout"]
        if passphrase != None:
            openssl_args = ["openssl", "ec", "-in", "/dev/stdin", "-pubout", "-noout", "-passin", "pass:" + passphrase]
        res = ctx.run(openssl_args + ["-text", "-noout"], mutates=False)
        if res.rc != 0:
            # Try Ed25519/Ed448 keys
            openssl_args = ["openssl", "ed25519", "-in", "/dev/stdin", "-pubout", "-noout"]
            if passphrase != None:
                fail("passphrase not supported for Ed25519 keys")
            res = ctx.run(openssl_args, mutates=False)
            if res.rc != 0:
                return {
                    "changed": False,
                    "can_load_key": True,
                    "can_parse_key": False,
                    "key_is_consistent": None,
                    "msg": "Failed to parse private key"
                }

    result = {
        "changed": False,
        "can_load_key": True,
        "can_parse_key": True,
        "key_is_consistent": None,
    }

    # Extract public key via openssl
    openssl_pub_args = ["openssl", "rsa", "-in", "/dev/stdin", "-pubout"]
    if passphrase != None:
        openssl_pub_args = ["openssl", "rsa", "-in", "/dev/stdin", "-pubout", "-passin", "pass:" + passphrase]

    res = ctx.run(openssl_pub_args, mutates=False, ok_codes=[0, 1])
    if res.rc == 0:
        public_key = res.stdout.strip()
        result["public_key"] = public_key

        # Extract fingerprint via openssl
        fp_res = ctx.run(["openssl", "rsa", "-pubin", "-in", "/dev/stdin", "-fingerprint", "-sha256"], mutates=False, ok_codes=[0, 1])
        if fp_res.rc == 0:
            # Parse output like "SHA256 Fingerprint=AA:BB:CC..."
            line = fp_res.stdout.strip()
            if "=" in line:
                fp_val = line.split("=", 1)[1].strip()
                result.setdefault("public_key_fingerprints", {})
                result["public_key_fingerprints"]["sha256"] = fp_val.lower()
        # Try SHA512
        fp_res = ctx.run(["openssl", "rsa", "-pubin", "-in", "/dev/stdin", "-fingerprint", "-sha512"], mutates=False, ok_codes=[0, 1])
        if fp_res.rc == 0:
            line = fp_res.stdout.strip()
            if "=" in line:
                fp_val = line.split("=", 1)[1].strip()
                result.setdefault("public_key_fingerprints", {})
                result["public_key_fingerprints"]["sha512"] = fp_val.lower()
    else:
        # Try EC key format for public key extraction
        openssl_pub_args = ["openssl", "ec", "-in", "/dev/stdin", "-pubout"]
        if passphrase != None:
            openssl_pub_args = ["openssl", "ec", "-in", "/dev/stdin", "-pubout", "-passin", "pass:" + passphrase]
        res = ctx.run(openssl_pub_args, mutates=False, ok_codes=[0, 1])
        if res.rc == 0:
            public_key = res.stdout.strip()
            result["public_key"] = public_key

    # Determine key type from OpenSSL output
    key_type = "unknown"
    openssl_info_args = ["openssl", "rsa", "-in", "/dev/stdin", "-text", "-noout"]
    if passphrase != None:
        openssl_info_args = ["openssl", "rsa", "-in", "/dev/stdin", "-text", "-noout", "-passin", "pass:" + passphrase]

    res = ctx.run(openssl_info_args, mutates=False, ok_codes=[0, 1])
    if res.rc == 0:
        out = res.stdout
        if "Private-Key:" in out:
            if "256 bit" in out or "256" in out.split("Private-Key:")[1].split("\n")[0]:
                key_type = "Ed25519"
            elif "448 bit" in out or "448" in out.split("Private-Key:")[1].split("\n")[0]:
                key_type = "Ed448"
            elif "RSA Public-Key:" in out or "RSA" in out:
                key_type = "RSA"
            elif "EC Public Key" in out:
                key_type = "ECC"
            elif "DSA Public Key" in out:
                key_type = "DSA"
            elif "Public-Key:" in out:
                line = out.split("Public-Key:")[1].split("\n")[0]
                if "256" in line:
                    key_type = "ECC"
                elif "384" in line:
                    key_type = "ECC"
                elif "521" in line:
                    key_type = "ECC"
                elif "1024" in line or "2048" in line or "3072" in line or "4096" in line:
                    key_type = "DSA"
                elif "RSA" in line:
                    key_type = "RSA"
                else:
                    key_type = "unknown"
        else:
            key_type = "RSA"

    result["type"] = key_type

    # Extract public key data (size and modulus/exponent for RSA, curve info for ECC)
    if key_type == "RSA":
        # Try to extract size and modulus
        openssl_mod_args = ["openssl", "rsa", "-in", "/dev/stdin", "-text", "-noout"]
        if passphrase != None:
            openssl_mod_args = ["openssl", "rsa", "-in", "/dev/stdin", "-text", "-noout", "-passin", "pass:" + passphrase]
        res = ctx.run(openssl_mod_args, mutates=False, ok_codes=[0, 1])
        if res.rc == 0:
            out = res.stdout
            # Extract modulus size from line like "Private-Key: 2048 bit"
            size = None
            for line in out.split("\n"):
                if "Private-Key:" in line:
                    for token in line.split():
                        if token.isdigit():
                            size = int(token)
                            break
                    break
            if size != None:
                result.setdefault("public_data", {})
                result["public_data"]["size"] = size
    elif key_type == "ECC":
        openssl_curve_args = ["openssl", "ec", "-in", "/dev/stdin", "-text", "-noout"]
        if passphrase != None:
            openssl_curve_args = ["openssl", "ec", "-in", "/dev/stdin", "-text", "-noout", "-passin", "pass:" + passphrase]
        res = ctx.run(openssl_curve_args, mutates=False, ok_codes=[0, 1])
        if res.rc == 0:
            out = res.stdout
            # Extract curve name
            for line in out.split("\n"):
                if "ASN1 OID:" in line:
                    curve = line.split(":")[1].strip()
                    result.setdefault("public_data", {})
                    result["public_data"]["curve"] = curve
                    break

    # Check consistency if requested (not supported in Starlark — fail gracefully)
    if check_consistency:
        fail("consistency checking is not supported in the Starlark runtime")

    return result
