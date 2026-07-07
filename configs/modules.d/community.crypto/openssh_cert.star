def main(ctx, params):
    path = params["path"]
    state = params.get("state", "present")
    cert_type = params.get("type")
    force = params.get("force", False)
    regenerate = params.get("regenerate", "partial_idempotence")
    if force:
        regenerate = "always"

    # Required params for present state
    if state == "present":
        if not cert_type:
            fail("type is required when state is present")
        if not params.get("signing_key"):
            fail("signing_key is required when state is present")
        if not params.get("public_key"):
            fail("public_key is required when state is present")
        if not params.get("valid_from"):
            fail("valid_from is required when state is present")
        if not params.get("valid_to"):
            fail("valid_to is required when state is present")
        if params.get("options") and cert_type == "host":
            fail("options can only be used with user certificates")

    # Handle absent state
    if state == "absent":
        if ctx.file_exists(path):
            res = ctx.run(["ssh-keygen", "-L", "-f", path], mutates=False)
            if res.rc == 0:
                # Certificate exists and is valid
                if ctx.check_mode:
                    return {"changed": True, "msg": "would remove certificate"}
                res = ctx.run(["ssh-keygen", "-z", "0", "-U", path], mutates=True)
                if res.rc != 0:
                    fail("failed to remove certificate: " + res.stderr)
                if ctx.file_exists(path):
                    fail("failed to remove certificate")
                return {"changed": True, "msg": "removed certificate"}
        return {"changed": False, "msg": "certificate already absent"}

    # Present state logic
    if not ctx.file_exists(path):
        # No existing cert - must generate
        if ctx.check_mode:
            return {"changed": True, "msg": "would generate new certificate"}
        res = _generate_certificate(ctx, params)
        if res.rc != 0:
            fail("failed to generate certificate: " + res.stderr)
        return {"changed": True, "msg": "generated new certificate"}

    # Certificate exists - check regeneration based on regenerate policy
    original = _read_certificate(ctx, path)
    if regenerate == "never":
        return {"changed": False, "msg": "certificate exists, regeneration disabled"}
    elif regenerate == "fail":
        if not _is_fully_valid(ctx, original, params):
            fail("certificate does not match the provided options")
        return {"changed": False, "msg": "certificate exists and is valid"}
    elif regenerate == "partial_idempotence":
        if _is_partially_valid(ctx, original, params):
            return {"changed": False, "msg": "certificate is partially valid"}
    elif regenerate == "full_idempotence":
        if _is_fully_valid(ctx, original, params):
            return {"changed": False, "msg": "certificate is fully valid"}

    # Must regenerate
    if ctx.check_mode:
        return {"changed": True, "msg": "would regenerate certificate"}
    res = _generate_certificate(ctx, params)
    if res.rc != 0:
        fail("failed to regenerate certificate: " + res.stderr)
    return {"changed": True, "msg": "regenerated certificate"}


def _generate_certificate(ctx, params):
    signing_key = params["signing_key"]
    public_key = params["public_key"]
    cert_type = params["type"]
    valid_from = params["valid_from"]
    valid_to = params["valid_to"]
    pkcs11_provider = params.get("pkcs11_provider")
    principals = params.get("principals", [])
    options = params.get("options", [])
    identifier = params.get("identifier", "")
    serial_number = params.get("serial_number")
    signature_algorithm = params.get("signature_algorithm")
    use_agent = params.get("use_agent", False)

    args = [
        "ssh-keygen",
        "-s", signing_key,
        "-I", identifier,
        "-n", ",".join(principals) if principals else "",
        "-t", cert_type,
        "-V", valid_from + ":" + valid_to,
    ]

    if signature_algorithm:
        args.extend(["-s", signature_algorithm])
    if serial_number != None:
        args.extend(["-z", str(serial_number)])
    if use_agent:
        args.append("-U")
    if pkcs11_provider:
        args.extend(["-D", pkcs11_provider])
    if options:
        args.append("-o")
        for opt in options:
            args.extend(["-O", opt])
    args.append(public_key)

    # ssh-keygen writes cert to same dir as public key with -cert.pub suffix
    return ctx.run(args, mutates=True)


def _read_certificate(ctx, path):
    res = ctx.run(["ssh-keygen", "-L", "-f", path], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout


def _parse_cert_info(stdout):
    data = {}
    current_key = None
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("Type:"):
            data["type"] = line.split(":", 1)[1].strip()
        elif line.startswith("Public key:"):
            data["public_key"] = line.split(":", 1)[1].strip()
        elif line.startswith("Signing key:"):
            data["signing_key"] = line.split(":", 1)[1].strip()
        elif line.startswith("Principals:"):
            data["principals"] = []
            current_key = "principals"
        elif line.startswith("Critical Options:"):
            current_key = "critical_options"
        elif line.startswith("Extensions:"):
            current_key = "extensions"
        elif current_key == "principals":
            data["principals"].append(line.strip())
        elif current_key in ("critical_options", "extensions"):
            # Skip options/extensions details for simplicity
            continue
        elif line.startswith("Serial:"):
            data["serial"] = int(line.split(":", 1)[1].strip())
        elif line.startswith("Valid:"):
            # Format: "Valid: from 2024-01-01T00:00:00 to 2025-01-01T00:00:00"
            parts = line.split(":", 1)[1].strip().split()
            if len(parts) >= 4:
                data["valid_from"] = parts[1]
                data["valid_to"] = parts[3]
        elif line.startswith("Signature algorithm:"):
            data["signature_algorithm"] = line.split(":", 1)[1].strip()
        elif line.startswith("Key ID:"):
            data["key_id"] = line.split(":", 1)[1].strip()
    return data


def _is_partially_valid(ctx, original, params):
    if not original:
        return False

    cert = _parse_cert_info(original)
    if not cert:
        return False

    # Compare types
    if cert.get("type") != params["type"]:
        return False

    # Compare principals
    cert_principals = set(cert.get("principals", []))
    param_principals = set(params.get("principals", []))
    if cert_principals != param_principals:
        return False

    # Compare signature algorithm if specified
    sig_algo = params.get("signature_algorithm")
    if sig_algo and cert.get("signature_algorithm") != sig_algo:
        return False

    # Compare serial number if specified
    serial = params.get("serial_number")
    if serial != None and cert.get("serial") != serial:
        return False

    # Compare timestamps if not ignoring them
    if not params.get("ignore_timestamps", False):
        valid_from = params.get("valid_from")
        valid_to = params.get("valid_to")
        if valid_from and cert.get("valid_from") != valid_from:
            return False
        if valid_to and cert.get("valid_to") != valid_to:
            return False

    return True


def _is_fully_valid(ctx, original, params):
    if not _is_partially_valid(ctx, original, params):
        return False

    cert = _parse_cert_info(original)
    if not cert:
        return False

    # Compare identifier (Key ID)
    identifier = params.get("identifier", "")
    if cert.get("key_id") != identifier:
        return False

    # Get key fingerprints
    signing_key = params.get("signing_key")
    public_key = params.get("public_key")
    cert_signing_fp = _get_key_fingerprint(ctx, cert.get("signing_key", ""))
    cert_public_fp = _get_key_fingerprint(ctx, cert.get("public_key", ""))
    param_signing_fp = _get_key_fingerprint(ctx, signing_key)
    param_public_fp = _get_key_fingerprint(ctx, public_key)

    if cert_signing_fp != param_signing_fp or cert_public_fp != param_public_fp:
        return False

    return True


def _get_key_fingerprint(ctx, key_path):
    if not key_path:
        return ""
    res = ctx.run(["ssh-keygen", "-l", "-f", key_path], mutates=False)
    if res.rc != 0:
        return ""
    # Format: "256 SHA256:abc... comment (RSA)"
    parts = res.stdout.strip().split()
    return parts[1] if len(parts) >= 2 else ""
