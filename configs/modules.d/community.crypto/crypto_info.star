def main(ctx, params):
    result = {}

    # Detect Python cryptography library
    res = ctx.run([
        "python", "-c",
        "import cryptography; print(cryptography.__version__)"
    ], mutates=False)
    if res.rc == 0:
        version = res.stdout.strip()
        result["python_cryptography_installed"] = True
        result["python_cryptography_capabilities"] = {
            "version": version,
            "curves": [],
            "has_ec": False,
            "has_ec_sign": False,
            "has_ed25519": False,
            "has_ed25519_sign": False,
            "has_ed448": False,
            "has_ed448_sign": False,
            "has_dsa": False,
            "has_dsa_sign": False,
            "has_rsa": False,
            "has_rsa_sign": False,
            "has_x25519": False,
            "has_x25519_serialization": False,
            "has_x448": False,
        }
        # Basic curve detection via Python
        cap_res = ctx.run([
            "python", "-c",
            "from cryptography.hazmat.primitives.asymmetric import ec; ec.generate_private_key(ec.SECP256R1()); print('ok')"
        ], mutates=False)
        if cap_res.rc == 0 and cap_res.stdout.strip() == "ok":
            result["python_cryptography_capabilities"]["curves"].append("secp256r1")
            result["python_cryptography_capabilities"]["has_ec"] = True
            result["python_cryptography_capabilities"]["has_ec_sign"] = True
    else:
        result["python_cryptography_installed"] = False
        result["python_cryptography_import_error"] = "cryptography library not available"

    # Detect OpenSSL binary
    openssl_path = ctx.run(["which", "openssl"], mutates=False)
    if openssl_path.rc == 0:
        path = openssl_path.stdout.strip()
        ver_res = ctx.run([path, "version"], mutates=False)
        if ver_res.rc == 0:
            output = ver_res.stdout
            parts = output.split(None, 2)
            version = parts[1] if len(parts) > 1 else ""
            result["openssl_present"] = True
            result["openssl"] = {
                "path": path,
                "version": version,
                "version_output": output,
            }
        else:
            result["openssl_present"] = False
    else:
        result["openssl_present"] = False

    return {"changed": False, "msg": "gathered cryptographic information", "data": result}
