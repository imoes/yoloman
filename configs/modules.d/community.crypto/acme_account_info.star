def main(ctx, params):
    # Extract parameters
    account_key_content = params.get("account_key_content")
    account_key_src = params.get("account_key_src")
    account_uri = params.get("account_uri")
    acme_directory = params["acme_directory"]
    acme_version = params["acme_version"]
    retrieve_orders = params.get("retrieve_orders", "ignore")
    select_crypto_backend = params.get("select_crypto_backend", "auto")
    validate_certs = params.get("validate_certs", True)
    account_key_passphrase = params.get("account_key_passphrase")
    request_timeout = params.get("request_timeout", 10)

    # Validation
    if account_key_content != None and account_key_src != None:
        fail("account_key_content and account_key_src are mutually exclusive")
    if account_key_content == None and account_key_src == None:
        fail("one of account_key_content or account_key_src is required")
    if acme_version not in [1, 2]:
        fail("acme_version must be 1 or 2")
    if retrieve_orders not in ["ignore", "url_list", "object_list"]:
        fail("retrieve_orders must be one of: ignore, url_list, object_list")
    if select_crypto_backend not in ["auto", "cryptography", "openssl"]:
        fail("select_crypto_backend must be one of: auto, cryptography, openssl")

    # Check mode: we cannot determine existence without actually querying the ACME directory
    if ctx.check_mode:
        return {
            "changed": False,
            "msg": "would retrieve ACME account information",
            "data": {
                "exists": None,  # Unknown in check_mode without live query
                "account_uri": None,
            },
        }

    # Prepare temporary key file if needed (account_key_content needs a temp file)
    key_path = None
    if account_key_content != None:
        tmp_res = ctx.run(["mktemp", "acme_XXXXXX.key"])
        key_path = tmp_res.stdout.strip()
        ctx.file_write(key_path, account_key_content, "0600")

    # Test key readability (via openssl)
    test_cmd = []
    if account_key_src:
        test_cmd = ["openssl", "rsa", "-in", account_key_src, "-check", "-noout", "-quiet"]
        res = ctx.run(test_cmd, mutates=False)
        if res.rc != 0:
            test_cmd = ["openssl", "ec", "-in", account_key_src, "-check", "-noout", "-quiet"]
            res = ctx.run(test_cmd, mutates=False)
    else:
        test_cmd = ["openssl", "rsa", "-in", key_path, "-check", "-noout", "-quiet"]
        res = ctx.run(test_cmd, mutates=False)
        if res.rc != 0:
            test_cmd = ["openssl", "ec", "-in", key_path, "-check", "-noout", "-quiet"]
            res = ctx.run(test_cmd, mutates=False)
    if res.rc != 0:
        fail("cannot parse account key: " + res.stderr)

    # Call external helper to perform ACME operations
    helper_cmd = ["acme_account_info_helper"]
    helper_cmd.extend(["--directory", acme_directory])
    helper_cmd.extend(["--version", str(acme_version)])
    if account_key_src:
        helper_cmd.extend(["--key-file", account_key_src])
    else:
        helper_cmd.extend(["--key-content", key_path])
    if account_uri:
        helper_cmd.extend(["--account-uri", account_uri])
    if select_crypto_backend != "auto":
        helper_cmd.extend(["--backend", select_crypto_backend])
    if not validate_certs:
        helper_cmd.append("--no-validate-certs")
    helper_cmd.extend(["--retrieve-orders", retrieve_orders])
    helper_cmd.extend(["--timeout", str(request_timeout)])
    if account_key_passphrase:
        helper_cmd.extend(["--passphrase", account_key_passphrase])

    res = ctx.run(helper_cmd, mutates=False)
    if res.rc != 0:
        fail("acme_account_info_helper failed: " + res.stderr)

    # Parse output (helper must output key=value pairs for Starlark compatibility)
    lines = res.stdout.strip().split("\n")
    data = {}
    for line in lines:
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v

    # Convert basic types
    exists = data.get("exists", "").lower() == "true"
    account_uri_result = data.get("account_uri")
    if account_uri_result == "" or account_uri_result == None:
        account_uri_result = None

    # Parse contact list
    contact_raw = data.get("account_contact", "")
    if contact_raw == "" or contact_raw == None:
        contact_list = []
    else:
        contact_list = _parse_list(contact_raw)

    account_info = None
    if exists and account_uri_result != None:
        account_info = {
            "contact": contact_list,
            "status": data.get("account_status", "valid"),
            "orders": data.get("account_orders", ""),
            "public_account_key": data.get("account_key", ""),
        }

    result = {
        "changed": False,
        "msg": "ACME account information retrieved",
        "data": {
            "exists": exists,
            "account_uri": account_uri_result,
        },
    }
    if exists and account_info != None:
        result["data"]["account"] = account_info

    # Handle order URIs
    order_uris_raw = data.get("order_uris", "")
    if order_uris_raw != "" and order_uris_raw != None:
        order_uris = _parse_list(order_uris_raw)
        result["data"]["order_uris"] = order_uris
        if retrieve_orders == "object_list":
            orders_raw = data.get("orders", "")
            if orders_raw != "" and orders_raw != None:
                orders_list = _parse_list(orders_raw)
                result["data"]["orders"] = orders_list

    # Cleanup temporary key file
    if key_path != None:
        ctx.run(["rm", "-f", key_path], mutates=True)

    return result


def _parse_list(s):
    if s == "" or s == None:
        return []
    if not s.startswith("[") or not s.endswith("]"):
        return [s]
    inner = s[1:-1].strip()
    if inner == "":
        return []
    items = []
    for item in inner.split(","):
        item = item.strip()
        if item.startswith("\"") and item.endswith("\""):
            item = item[1:-1]
        elif item.startswith("'") and item.endswith("'"):
            item = item[1:-1]
        if item != "":
            items.append(item)
    return items
