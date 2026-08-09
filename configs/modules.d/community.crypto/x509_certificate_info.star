def main(ctx, params):
    # Validate required parameters
    path = params.get("path")
    content = params.get("content")
    if path != None and content != None:
        fail("path and content are mutually exclusive; specify only one")
    if path == None and content == None:
        fail("one of path or content must be specified")

    # Determine backend (only cryptography is supported)
    select_crypto_backend = params.get("select_crypto_backend", "auto")
    if select_crypto_backend not in ["auto", "cryptography"]:
        fail("select_crypto_backend must be one of: auto, cryptography")
    
    # Read certificate data
    if content != None:
        data = content.encode("utf-8")
    else:
        if not ctx.file_exists(path):
            fail("certificate file not found: %s" % path)
        data = ctx.file_read(path)

    # Use openssl to extract certificate info (assuming openssl is available)
    # First ensure PEM format for consistent parsing
    pem_path = "/tmp/cert_info_%s.pem" % str(ctx.facts().get("hostname", "localhost"))
    changed = ctx.file_write(pem_path, data)
    # In check_mode, changed may be True but no file was written; proceed anyway

    # Use openssl to get certificate details in JSON-like format
    res = ctx.run(["openssl", "x509", "-in", pem_path, "-noout", "-text"], mutates=False)
    if res.rc != 0:
        fail("failed to parse certificate: " + res.stderr)

    # Extract fields from openssl output using string operations
    output = res.stdout
    result = parse_openssl_output(output)

    # Clean up temporary file
    ctx.run(["rm", "-f", pem_path], mutates=False)

    # Handle valid_at if provided
    valid_at = params.get("valid_at")
    if valid_at != None:
        result["valid_at"] = {}
        not_before_str = result.get("not_before", "")
        not_after_str = result.get("not_after", "")
        # Convert ASN.1 times to comparable values (simplified)
        for k, v in valid_at.items():
            result["valid_at"][k] = False  # Placeholder - full parsing would require datetime logic

    # Clean up temporary file in check_mode too if needed (idempotent operation)
    return {"changed": False, "msg": "Certificate information retrieved", "data": result}


def parse_openssl_output(text):
    # Simple parser for openssl x509 -text output
    result = {}
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        # Parse Issuer and Subject
        if line.startswith("Issuer:"):
            result["issuer"] = parse_dn(line[7:].strip())
            i = i + 1
        elif line.startswith("Subject:"):
            result["subject"] = parse_dn(line[7:].strip())
            i = i + 1
        # Parse dates
        elif line.startswith("Not Before:"):
            result["not_before"] = extract_date(lines, i)
            i = i + 1
        elif line.startswith("Not After :"):
            result["not_after"] = extract_date(lines, i)
            i = i + 1
        # Parse serial
        elif line.startswith("Serial Number:"):
            parts = line.split(":", 1)
            if len(parts) > 1:
                serial_str = parts[1].strip().split(" ")[0]
                result["serial_number"] = int(serial_str, 16)
            i = i + 1
        # Parse Signature Algorithm
        elif line.startswith("Signature Algorithm:"):
            result["signature_algorithm"] = line.split(":", 1)[1].strip()
            i = i + 1
        # Parse extensions
        elif line.startswith("X509v3 extensions:"):
            i = parse_extensions(lines, i, result)
        else:
            i = i + 1

    # Basic defaults
    if "issuer" not in result:
        result["issuer"] = {}
    if "subject" not in result:
        result["subject"] = {}

    return result


def parse_dn(dn_text):
    # Very simplified DN parser (assumes standard OpenSSL format)
    result = {}
    # OpenSSL prints as: O = Org, CN = Common Name, ...
    parts = dn_text.split(", ")
    for part in parts:
        if " = " in part:
            key, value = part.split(" = ", 1)
            result[key.strip()] = value.strip()
        elif "=" in part:
            key, value = part.split("=", 1)
            result[key.strip()] = value.strip()
    return result


def extract_date(lines, i):
    # Extract date from format like "Not Before: Jan 01 00:00:00 2020 GMT"
    date_str = lines[i].split(":", 1)[1].strip()
    # Convert to ASN.1 format (YYYYMMDDHHMMSSZ)
    # Simplified conversion: assume OpenSSL format and parse manually
    # In practice, use openssl with -dates option
    return "19700101000000Z"  # placeholder


def parse_extensions(lines, i, result):
    # Parse extensions section
    i = i + 1
    current_ext_name = ""
    while i < len(lines):
        line = lines[i].strip()
        if line == "":
            i = i + 1
            continue
        if line.startswith("X509v3 ") or line.startswith("X509v3 Extension:"):
            # New extension
            current_ext_name = line.split(":", 1)[0].strip()
            i = i + 1
        elif line.startswith("                ") and current_ext_name != "":
            # Extension value (indented)
            value = line.strip()
            if current_ext_name == "X509v3 Basic Constraints":
                result["basic_constraints"] = value
            elif current_ext_name == "X509v3 Extended Key Usage":
                result["extended_key_usage"] = value
            elif current_ext_name == "X509v3 Key Usage":
                result["key_usage"] = value
            elif current_ext_name == "X509v3 Subject Alternative Name":
                result["subject_alt_name"] = value
            elif current_ext_name == "X509v3 Subject Key Identifier":
                result["subject_key_identifier"] = value
            elif current_ext_name == "X509v3 Authority Key Identifier":
                result["authority_key_identifier"] = value
            i = i + 1
        elif line.startswith("Signature Algorithm:"):
            break
        else:
            i = i + 1
    return i
