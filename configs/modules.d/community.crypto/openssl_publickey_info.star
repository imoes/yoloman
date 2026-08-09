def main(ctx, params):
    # Validate required arguments
    path = params.get("path")
    content = params.get("content")
    backend_choice = params.get("select_crypto_backend", "auto")

    # Must specify exactly one of path or content
    if path == None and content == None:
        fail("One of 'path' or 'content' must be specified")
    if path != None and content != None:
        fail("Only one of 'path' or 'content' may be specified")

    # Only cryptography backend is supported in Starlark
    if backend_choice != "auto" and backend_choice != "cryptography":
        fail("select_crypto_backend must be 'auto' or 'cryptography'")

    # Read key data
    data_str = ""
    if path != None:
        data_str = ctx.file_read(path)
    else:
        data_str = content
    data = data_str.encode("utf-8")

    # Use openssl command to extract public key info (fallback for Starlark)
    # First try generic public key parsing
    res = ctx.run(["openssl", "pubin", "-inform", "PEM", "-text", "-noout"], mutates=False)
    if res.rc == 0:
        # Parsing succeeded with pubin, get full details
        res = ctx.run(["openssl", "pubin", "-inform", "PEM", "-text"], mutates=False)
        output = res.stdout

        # Determine type and parse accordingly
        lines = output.split("\n")
        key_type = "unknown"
        size = 0
        curve = ""
        x = 0
        y = 0
        modulus = 0
        exponent = 0

        for line in lines:
            if "RSA Public-Key:" in line or "Public-Key:" in line and "RSA" in line:
                key_type = "RSA"
            elif "Public-Key:" in line and "EC" in line:
                key_type = "ECC"
            elif "ASN1 OID:" in line:
                curve = line.split(":")[1].strip()
            elif "NIST CURVE:" in line:
                curve = line.split(":")[1].strip()
            elif "pub:" in line and key_type == "ECC":
                # Extract EC coordinates
                idx = lines.index(line)
                coord_lines = []
                while idx + 1 < len(lines) and lines[idx + 1].strip() and not lines[idx + 1].strip().startswith("ASN1 OID:") and not lines[idx + 1].strip().startswith("NIST CURVE:"):
                    coord_lines.append(lines[idx + 1].strip().replace(":", ""))
                    idx += 1
                coord_hex = "".join(coord_lines)
                if len(coord_hex) >= 2:
                    half = len(coord_hex) // 2
                    x_hex = coord_hex[:half]
                    y_hex = coord_hex[half:]
                    x = int(x_hex, 16) if x_hex else 0
                    y = int(y_hex, 16) if y_hex else 0
            elif "Modulus:" in line and key_type == "RSA":
                idx = lines.index(line)
                modulus_lines = []
                while idx + 1 < len(lines) and lines[idx + 1].strip() and not lines[idx + 1].strip().startswith("Exponent:"):
                    modulus_lines.append(lines[idx + 1].strip().replace(":", ""))
                    idx += 1
                modulus_hex = "".join(modulus_lines)
                modulus = int(modulus_hex, 16)
            elif "Exponent:" in line and key_type == "RSA":
                exp_line = line.split(":")[1].strip()
                if "(" in exp_line:
                    exp_line = exp_line.split("(")[0].strip()
                exponent = int(exp_line)
            elif "Public-Key:" in line:
                # Extract bit size from line like "Public-Key: (2048 bit)"
                start = line.find("(")
                end = line.find("bit")
                if start != -1 and end != -1:
                    size_str = line[start + 1:end].strip()
                    size = int(size_str)

        # Set size from curve if available for ECC
        if key_type == "ECC" and size == 0 and curve != "":
            if curve.find("256") != -1:
                size = 256
            elif curve.find("384") != -1:
                size = 384
            elif curve.find("521") != -1:
                size = 521

        # Build public_data based on key type
        public_data = {}
        if key_type == "RSA":
            if size == 0 and modulus > 0:
                size = (len(bin(modulus)) - 2) // 8 * 8
            public_data = {"size": size, "modulus": modulus, "exponent": exponent}
        elif key_type == "ECC":
            public_data = {"size": size, "curve": curve, "x": x, "y": y}

        return {
            "changed": False,
            "msg": "successfully parsed public key",
            "data": {
                "type": key_type,
                "public_data": public_data,
                "fingerprints": {}
            }
        }

    # Fallback to specific key type parsing if generic pubin fails
    # Try RSA first
    res = ctx.run(["openssl", "rsa", "-pubin", "-inform", "PEM", "-text", "-noout"], mutates=False)
    if res.rc == 0:
        res = ctx.run(["openssl", "rsa", "-pubin", "-inform", "PEM", "-text"], mutates=False)
        output = res.stdout
        lines = output.split("\n")
        modulus = 0
        exponent = 0
        size = 0
        for line in lines:
            if "Public-Key:" in line:
                start = line.find("(")
                end = line.find("bit")
                if start != -1 and end != -1:
                    size_str = line[start + 1:end].strip()
                    size = int(size_str)
            elif "Modulus:" in line:
                idx = lines.index(line)
                modulus_lines = []
                while idx + 1 < len(lines) and lines[idx + 1].strip() and not lines[idx + 1].strip().startswith("Exponent:"):
                    modulus_lines.append(lines[idx + 1].strip().replace(":", ""))
                    idx += 1
                modulus_hex = "".join(modulus_lines)
                modulus = int(modulus_hex, 16)
            elif "Exponent:" in line:
                exp_line = line.split(":")[1].strip()
                if "(" in exp_line:
                    exp_line = exp_line.split("(")[0].strip()
                exponent = int(exp_line)

        return {
            "changed": False,
            "msg": "successfully parsed RSA public key",
            "data": {
                "type": "RSA",
                "public_data": {"size": size, "modulus": modulus, "exponent": exponent},
                "fingerprints": {}
            }
        }

    # Try EC
    res = ctx.run(["openssl", "ec", "-pubin", "-inform", "PEM", "-text", "-noout"], mutates=False)
    if res.rc == 0:
        res = ctx.run(["openssl", "ec", "-pubin", "-inform", "PEM", "-text"], mutates=False)
        output = res.stdout
        lines = output.split("\n")
        curve = ""
        size = 0
        x = 0
        y = 0
        for line in lines:
            if "ASN1 OID:" in line:
                curve = line.split(":")[1].strip()
            elif "NIST CURVE:" in line:
                curve = line.split(":")[1].strip()
            elif "pub:" in line:
                idx = lines.index(line)
                coord_lines = []
                while idx + 1 < len(lines) and lines[idx + 1].strip() and not lines[idx + 1].strip().startswith("ASN1 OID:") and not lines[idx + 1].strip().startswith("NIST CURVE:"):
                    coord_lines.append(lines[idx + 1].strip().replace(":", ""))
                    idx += 1
                coord_hex = "".join(coord_lines)
                if len(coord_hex) >= 2:
                    half = len(coord_hex) // 2
                    x_hex = coord_hex[:half]
                    y_hex = coord_hex[half:]
                    x = int(x_hex, 16) if x_hex else 0
                    y = int(y_hex, 16) if y_hex else 0

        # Determine size from curve
        if curve != "":
            if curve.find("256") != -1:
                size = 256
            elif curve.find("384") != -1:
                size = 384
            elif curve.find("521") != -1:
                size = 521

        return {
            "changed": False,
            "msg": "successfully parsed EC public key",
            "data": {
                "type": "ECC",
                "public_data": {"size": size, "curve": curve, "x": x, "y": y},
                "fingerprints": {}
            }
        }

    fail("Could not parse public key with available OpenSSL commands")
