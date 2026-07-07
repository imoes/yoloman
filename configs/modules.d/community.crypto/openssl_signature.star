def main(ctx, params):
    path = params["path"]
    privatekey_path = params.get("privatekey_path")
    privatekey_content = params.get("privatekey_content")
    passphrase = params.get("privatekey_passphrase")
    backend = params.get("select_crypto_backend", "auto")

    # Validate file exists (read-only)
    if not ctx.file_exists(path):
        fail("The file {0} does not exist".format(path))

    # Only cryptography backend is supported, but not in Starlark; use openssl CLI as fallback
    if backend == "cryptography":
        fail("The 'cryptography' backend is not available in Starlark runtime. Use 'auto' to fallback to openssl CLI.")

    # For 'auto', fallback to openssl CLI
    if privatekey_path == None and privatekey_content == None:
        fail("Either privatekey_path or privatekey_content must be specified.")
    if privatekey_path != None and privatekey_content != None:
        fail("Cannot specify both privatekey_path and privatekey_content.")

    # Handle private key
    key_arg = []
    temp_key_path = ""
    if privatekey_path != None:
        key_arg = ["-signkey", privatekey_path]
        if passphrase != None:
            key_arg = ["-signkey", privatekey_path, "-passin", "pass:" + passphrase]
    else:
        # Write content to temporary file
        temp_key_path = "/tmp/ansible_openssl_key_" + str(ctx.facts().get("timestamp", 0))
        # Note: ctx.facts() may not have timestamp; use static fallback or fail if needed
        # Since no reliable way to get unique suffix without timestamp, assume single sign per run
        temp_key_path = "/tmp/ansible_openssl_key.pem"
        if ctx.check_mode:
            # In check_mode, just predict change without writing
            return {"changed": True, "msg": "would sign {0}".format(path)}
        changed = ctx.file_write(temp_key_path, privatekey_content, "0600")
        key_arg = ["-signkey", temp_key_path]
        if passphrase != None:
            key_arg = ["-signkey", temp_key_path, "-passin", "pass:" + passphrase]

    # Run openssl dgst -sha256 -sign to file
    sig_file = "/tmp/ansible_openssl_sig.pem"
    if ctx.check_mode:
        return {"changed": True, "msg": "would sign {0}".format(path)}
    res = ctx.run(["openssl", "dgst", "-sha256"] + key_arg + ["-out", sig_file, path], mutates=True)
    if res.rc != 0:
        fail("openssl signing failed: {0}".format(res.stderr))

    # Read signature and base64 encode manually
    sig_raw = ctx.file_read(sig_file)
    b64 = _base64_encode(sig_raw)

    # Cleanup
    ctx.run(["rm", "-f", sig_file])
    if temp_key_path != "":
        ctx.run(["rm", "-f", temp_key_path])

    return {"changed": True, "signature": b64}


def _base64_encode(data):
    """Manual base64 encoding for Starlark (no base64 module)."""
    chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    result = ""
    i = 0
    length = len(data)
    while i < length:
        b1 = ord(data[i]) if i < length else 0
        b2 = ord(data[i+1]) if i+1 < length else 0
        b3 = ord(data[i+2]) if i+2 < length else 0
        enc1 = b1 >> 2
        enc2 = ((b1 & 3) << 4) | (b2 >> 4)
        enc3 = ((b2 & 15) << 2) | (b3 >> 6)
        enc4 = b3 & 63
        result += chars[enc1]
        result += chars[enc2]
        if i+1 < length:
            result += chars[enc3]
        else:
            result += "="
        if i+2 < length:
            result += chars[enc4]
        else:
            result += "="
        i += 3
    return result
