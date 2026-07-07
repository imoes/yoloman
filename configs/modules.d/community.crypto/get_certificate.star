def main(ctx, params):
    host = params["host"]
    port = params["port"]
    ca_cert_path = params.get("ca_cert")
    server_name = params.get("server_name")
    timeout = params.get("timeout", 10)
    ciphers = params.get("ciphers")
    starttls = params.get("starttls")
    proxy_host = params.get("proxy_host")
    proxy_port = params.get("proxy_port", 8080)
    asn1_base64 = params.get("asn1_base64", False)
    backend = params.get("select_crypto_backend", "auto")

    # Backend validation
    if backend not in ("auto", "cryptography"):
        fail("select_crypto_backend must be 'auto' or 'cryptography'")
    if backend == "auto":
        backend = "cryptography"  # assume available in Starlark runtime (embedded context)

    # Check ca_cert file existence
    if ca_cert_path != None:
        if not ctx.file_exists(ca_cert_path):
            fail("ca_cert file does not exist: " + ca_cert_path)

    # Build the certificate retrieval command
    cmd = ["openssl", "s_client", "-connect", host + ":" + str(port), "-showcerts"]

    if server_name != None:
        cmd.extend(["-servername", server_name])
    if ca_cert_path != None:
        cmd.extend(["-CAfile", ca_cert_path])
    if timeout != 10:
        cmd.extend(["-timeout", str(timeout)])
    if ciphers != None:
        cmd.extend(["-cipher", ":".join(ciphers)])
    if starttls == "mysql":
        cmd.append("-starttls")
        cmd.append("mysql")

    if proxy_host != None:
        fail("proxy_host is not supported in this Starlark implementation")

    res = ctx.run(cmd)
    if res.rc != 0:
        fail("openssl s_client failed: " + res.stderr)

    cert_pem = ""
    in_cert = False
    for line in res.stdout.splitlines():
        if line.strip() == "-----BEGIN CERTIFICATE-----":
            in_cert = True
            cert_pem += line + "\n"
        elif line.strip() == "-----END CERTIFICATE-----":
            if in_cert:
                cert_pem += line + "\n"
                break
        elif in_cert:
            cert_pem += line + "\n"

    if not cert_pem:
        fail("No certificate found in openssl output")

    # Write cert to temp file
    temp_cert_path = "/tmp/cert_" + str(hash(cert_pem)) + ".pem"
    ctx.file_write(temp_cert_path, cert_pem)

    # Extract details using openssl x509 commands
    subject_res = ctx.run(["openssl", "x509", "-subject", "-noout", "-in", temp_cert_path])
    issuer_res = ctx.run(["openssl", "x509", "-issuer", "-noout", "-in", temp_cert_path])
    dates_res = ctx.run(["openssl", "x509", "-dates", "-noout", "-in", temp_cert_path])
    serial_res = ctx.run(["openssl", "x509", "-serial", "-noout", "-in", temp_cert_path])
    sig_alg_res = ctx.run(["openssl", "x509", "-sigalg", "-noout", "-in", temp_cert_path])
    version_res = ctx.run(["openssl", "x509", "-version", "-noout", "-in", temp_cert_path])
    ext_res = ctx.run(["openssl", "x509", "-text", "-noout", "-in", temp_cert_path])

    def parse_key_value(res, prefix):
        for line in res.stdout.splitlines():
            if line.startswith(prefix):
                return line[len(prefix):].strip()
        return ""

    subject_str = parse_key_value(subject_res, "subject=")
    issuer_str = parse_key_value(issuer_res, "issuer=")
    not_before_str = parse_key_value(dates_res, "notBefore=")
    not_after_str = parse_key_value(dates_res, "notAfter=")
    serial_str = parse_key_value(serial_res, "serial=")
    sig_alg_str = parse_key_value(sig_alg_res, "")
    version_str = parse_key_value(version_res, "version=")

    def parse_dn(dn_str):
        result = {}
        parts = dn_str.split(",")
        for part in parts:
            part = part.strip()
            eq_idx = part.find("=")
            if eq_idx > 0:
                key = part[:eq_idx].strip()
                value = part[eq_idx+1:].strip()
                result[key] = value
        return result

    subject = parse_dn(subject_str)
    issuer = parse_dn(issuer_str)

    extensions = []
    text_lines = ext_res.stdout.splitlines()
    in_ext = False
    current_ext = {}
    for line in text_lines:
        stripped = line.strip()
        if stripped.startswith("X509v3 extensions:"):
            in_ext = True
            continue
        if not in_ext:
            continue
        if stripped == "":
            continue
        if stripped.startswith("X509v3 ") or stripped.startswith("X509v3 Extension"):
            if current_ext:
                extensions.append(current_ext)
            current_ext = {}
            name = stripped.rstrip(":").strip()
            current_ext["name"] = name
            current_ext["critical"] = False
            continue
        if stripped.startswith("Critical:"):
            current_ext["critical"] = "Yes" in stripped
            continue
        if "ASN.1:" in stripped or stripped.startswith("  "):
            data_part = stripped.strip()
            if asn1_base64:
                current_ext["asn1_data"] = base64_encode(data_part)
            else:
                current_ext["asn1_data"] = data_part
    if current_ext:
        extensions.append(current_ext)

    now_res = ctx.run(["date", "+%Y%m%d%H%M%SZ"])
    now_str = now_res.stdout.strip()
    expired = now_str > not_after_str

    return {
        "changed": False,
        "cert": cert_pem,
        "expired": expired,
        "extensions": extensions,
        "issuer": issuer,
        "not_after": not_after_str,
        "not_before": not_before_str,
        "serial_number": serial_str,
        "signature_algorithm": sig_alg_str,
        "subject": subject,
        "version": version_str
    }


def base64_encode(s):
    # Simple base64 implementation for ASCII strings
    chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    s_bytes = []
    for c in s:
        s_bytes.append(ord(c))
    
    result = ""
    i = 0
    while i < len(s_bytes):
        b1 = s_bytes[i]
        b2 = s_bytes[i + 1] if i + 1 < len(s_bytes) else 0
        b3 = s_bytes[i + 2] if i + 2 < len(s_bytes) else 0
        
        result += chars[(b1 >> 2) & 0x3F]
        result += chars[(((b1 & 0x03) << 4) | (b2 >> 4)) & 0x3F]
        
        if i + 1 < len(s_bytes):
            result += chars[(((b2 & 0x0F) << 2) | (b3 >> 6)) & 0x3F]
        else:
            result += "="
        
        if i + 2 < len(s_bytes):
            result += chars[b3 & 0x3F]
        else:
            result += "="
        
        i += 3
    
    return result
