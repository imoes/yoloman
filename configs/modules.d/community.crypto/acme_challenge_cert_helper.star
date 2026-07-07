def main(ctx, params):
    challenge = params["challenge"]
    challenge_data = params["challenge_data"]
    private_key_src = params.get("private_key_src")
    private_key_content = params.get("private_key_content")
    private_key_passphrase = params.get("private_key_passphrase")

    # Validate challenge type
    if challenge != "tls-alpn-01":
        fail("only tls-alpn-01 challenge is supported")

    # Validate private key args (mutual exclusivity already validated by runtime)
    if private_key_content == None and private_key_src == None:
        fail("one of private_key_src or private_key_content is required")

    # Load private key
    if private_key_content != None:
        pem_data = private_key_content
    else:
        pem_data = ctx.file_read(private_key_src)

    # Prepare passphrase argument for openssl
    passphrase_arg = []
    if private_key_passphrase != None:
        passphrase_arg = ["-passin", "pass:" + private_key_passphrase]

    # Extract identifier info from challenge_data
    resource = challenge_data.get("resource", "")
    resource_original = challenge_data.get("resource_original", "dns:" + resource)
    resource_value = challenge_data.get("resource_value", "")

    # Parse identifier_type and identifier
    parts = resource_original.split(":", 1)
    if len(parts) != 2:
        fail("invalid resource_original format: " + resource_original)
    identifier_type = parts[0]
    identifier = parts[1]

    # Validate identifier type
    if identifier_type not in ["dns", "ip"]:
        fail("unsupported identifier type: " + identifier_type)

    # Generate regular self-signed certificate using openssl
    subject = "/"
    res = ctx.run([
        "openssl", "req", "-new", "-x509", "-nodes",
        "-days", "10",
        "-key", "/dev/stdin",
        "-subj", subject,
        "-addext", "subjectAltName=" + identifier_type + ":" + identifier
    ] + passphrase_arg, mutates=False)
    if res.rc != 0:
        fail("failed to generate regular certificate: " + res.stderr)
    regular_certificate = res.stdout

    # Decode resource_value (base64) using openssl
    import_time = str(ctx.facts().get("hostname", "localhost")) + "_tmp"
    tmp_b64_path = "/tmp/acme_b64_" + import_time
    tmp_bin_path = "/tmp/acme_bin_" + import_time
    ctx.file_write(tmp_b64_path, resource_value)

    # Decode using openssl
    res = ctx.run([
        "openssl", "base64", "-d", "-A", "-in", tmp_b64_path, "-out", tmp_bin_path
    ], mutates=False)
    if res.rc != 0:
        fail("failed to decode resource_value: " + res.stderr)

    # Read binary value as hex via xxd
    res = ctx.run(["xxd", "-p", tmp_bin_path], mutates=False)
    if res.rc != 0:
        fail("failed to convert binary to hex: " + res.stderr)
    hex_data = res.stdout.replace("\n", "")

    # Clean up temp files
    ctx.run(["rm", "-f", tmp_b64_path, tmp_bin_path], mutates=False)

    # Build ASN1 encoded octet string (simple case: <=127 bytes)
    value_len = len(hex_data) // 2
    if value_len >= 128:
        fail("value length exceeds 128 bytes: " + str(value_len))

    # Construct extension config for openssl
    ext_config = "[ext]\nbasicConstraints = CA:FALSE\n" + \
                 "subjectAltName = " + identifier_type + ":" + identifier + "\n" + \
                 "1.3.6.1.5.5.7.1.31 = ASN1:OCTETSTRING:"

    # Hex encode length byte: 0x04 followed by length (as hex)
    length_hex = "%02x" % value_len
    ext_config += length_hex + hex_data

    # Write config file
    config_path = "/tmp/acme_challenge_cert_helper.cnf"
    ctx.file_write(config_path, ext_config)

    # Generate CSR first
    res = ctx.run([
        "openssl", "req", "-new",
        "-key", "/dev/stdin",
        "-subj", subject
    ] + passphrase_arg, mutates=False)
    if res.rc != 0:
        fail("failed to generate CSR: " + res.stderr)
    csr_pem = res.stdout

    # Sign CSR with custom extensions
    res = ctx.run([
        "openssl", "x509", "-req", "-days", "10",
        "-in", "/dev/stdin",
        "-signkey", "/dev/stdin",
        "-extfile", config_path,
        "-extensions", "ext"
    ] + passphrase_arg, mutates=False)
    if res.rc != 0:
        fail("failed to generate challenge certificate: " + res.stderr)
    challenge_certificate = res.stdout

    # Clean up config file
    ctx.run(["rm", "-f", config_path], mutates=False)

    # Return results
    return {
        "changed": True,
        "msg": "challenge certificates generated",
        "domain": resource,
        "identifier_type": identifier_type,
        "identifier": identifier,
        "challenge_certificate": challenge_certificate,
        "regular_certificate": regular_certificate
    }
