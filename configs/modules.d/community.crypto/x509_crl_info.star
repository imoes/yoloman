def main(ctx, params):
    path = params.get("path")
    content = params.get("content")
    list_revoked = params.get("list_revoked_certificates", True)
    name_encoding = params.get("name_encoding", "ignore")

    # Validate arguments
    if path == None and content == None:
        fail("Either 'path' or 'content' must be specified")
    if path != None and content != None:
        fail("Only one of 'path' or 'content' must be specified (not both)")

    # Read CRL data
    data = None
    if path != None:
        if not ctx.file_exists(path):
            fail("CRL file '{0}' does not exist".format(path))
        data = ctx.file_read(path).encode("utf-8")
    else:
        data = content.encode("utf-8")
        # Simple PEM detection: look for BEGIN/END markers
        if b"-----BEGIN CRL-----" not in data and b"-----BEGIN X509 CRL-----" not in data:
            fail("Content is neither PEM format nor Base64-encoded; decoding not supported in Starlark")

    # Use openssl to parse CRL
    cmd = ["openssl", "crl", "-inform", "PEM", "-text", "-noout"]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("Failed to parse CRL: " + res.stderr)

    # Parse output
    output = res.stdout
    issuer_ordered = []
    last_update = ""
    next_update = ""
    digest = ""
    revoked = []

    lines = output.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("Issuer:"):
            issuer_str = line[len("Issuer:"):].strip()
            parts = issuer_str.split("/")
            for part in parts:
                if "=" in part:
                    key_val = part.split("=", 1)
                    issuer_ordered.append([key_val[0].strip(), key_val[1].strip()])
        elif line.startswith("Last Update:"):
            last_update = line[len("Last Update:"):].strip()
        elif line.startswith("Next Update:"):
            next_update = line[len("Next Update:"):].strip()
        elif line.startswith("Signature Algorithm:"):
            digest = line[len("Signature Algorithm:"):].strip()
        elif line.startswith("Revoked Certificates:"):
            # Parse revoked certificates - simplified
            if list_revoked:
                i += 1
                while i < len(lines) and not lines[i].strip().startswith("-----"):
                    line2 = lines[i].strip()
                    if line2.startswith("Serial Number:"):
                        serial_hex = line2.split(":")[1].strip()
                        serial_int = int(serial_hex, 16)
                        # Default placeholder values for other fields
                        revoked.append({
                            "serial_number": serial_int,
                            "revocation_date": "",
                            "issuer": [],
                            "issuer_critical": False,
                            "reason": "",
                            "reason_critical": False,
                            "invalidity_date": "",
                            "invalidity_date_critical": False
                        })
                    elif line2.startswith("Revocation Date:"):
                        if len(revoked) > 0:
                            revoked[-1]["revocation_date"] = line2[len("Revocation Date:"):].strip()
                    i += 1
                i -= 1  # Step back one since outer loop increments
        i += 1

    # Build issuer dictionary (last occurrence wins per Ansible spec)
    issuer_dict = {}
    for k, v in issuer_ordered:
        issuer_dict[k] = v

    # Build result dict
    result_dict = {
        "format": "pem",
        "issuer": issuer_dict,
        "issuer_ordered": issuer_ordered,
        "last_update": last_update,
        "next_update": next_update,
        "digest": digest
    }
    if list_revoked:
        result_dict["revoked_certificates"] = revoked
    else:
        result_dict["revoked_certificates"] = []

    return {"changed": False, "msg": "Successfully parsed CRL", "data": result_dict}
