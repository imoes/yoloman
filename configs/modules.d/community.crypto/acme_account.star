def main(ctx, params):
    # Required parameters
    acme_directory = params["acme_directory"]
    acme_version = params["acme_version"]
    state = params["state"]

    # Optional parameters with defaults
    allow_creation = params.get("allow_creation", True)
    terms_agreed = params.get("terms_agreed", False)
    contact = params.get("contact", [])
    request_timeout = params.get("request_timeout", 10)
    validate_certs = params.get("validate_certs", True)
    select_crypto_backend = params.get("select_crypto_backend", "auto")

    # Account key handling
    account_key_src = params.get("account_key_src")
    account_key_content = params.get("account_key_content")
    account_uri = params.get("account_uri")

    # New account key handling (for changed_key state)
    new_account_key_src = params.get("new_account_key_src")
    new_account_key_content = params.get("new_account_key_content")
    new_account_key_passphrase = params.get("new_account_key_passphrase")

    # External account binding
    external_account_binding = params.get("external_account_binding")

    # Validate required mutual exclusivity and conditionals
    if account_key_src != None and account_key_content != None:
        fail("account_key_src and account_key_content are mutually exclusive")
    if account_key_src == None and account_key_content == None:
        fail("one of account_key_src or account_key_content is required")

    if new_account_key_src != None and new_account_key_content != None:
        fail("new_account_key_src and new_account_key_content are mutually exclusive")
    if state == "changed_key":
        if new_account_key_src == None and new_account_key_content == None:
            fail("new_account_key_src or new_account_key_content is required for changed_key state")

    # External account binding validation for v2 only
    if acme_version == 1 and external_account_binding != None:
        fail("external_account_binding is not supported for ACME v1")

    # Handle external_account_binding key padding if present
    if external_account_binding != None:
        key = external_account_binding.get("key", "")
        if len(key) % 4 != 0:
            key = key + ("=" * (4 - len(key) % 4))
        external_account_binding["key"] = key

    # Build command with all relevant arguments
    cmd_base = ["acme_account", "--directory", acme_directory, "--version", str(acme_version)]
    if validate_certs == False:
        cmd_base.append("--no-validate-certs")
    if select_crypto_backend == "cryptography":
        cmd_base.append("--backend")
        cmd_base.append("cryptography")
    elif select_crypto_backend == "openssl":
        cmd_base.append("--backend")
        cmd_base.append("openssl")
    cmd_base.extend(["--timeout", str(request_timeout)])

    # State handling
    changed = False
    account_uri_result = None
    msg = ""

    if state == "absent":
        # Deactivate account if exists
        probe = ctx.run(cmd_base + ["--state", "absent", "--check"], mutates=False)
        if probe.rc == 0:
            # Account exists; will deactivate
            if not ctx.check_mode:
                res = ctx.run(cmd_base + ["--state", "absent"], mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would deactivate account", "account_uri": account_uri_result}
                if res.rc != 0:
                    fail("failed to deactivate account: " + res.stderr)
            changed = True
            msg = "deactivated account"
        else:
            msg = "account does not exist"
        # Try to get current account URI (probe may have retrieved it)
        if probe.stdout.strip():
            account_uri_result = probe.stdout.strip().split("\n")[-1]
            if account_uri_result.startswith("{"):
                # simplistic JSON line extraction
                lines = probe.stdout.strip().split("\n")
                for line in lines:
                    if "account_uri" in line and ":" in line:
                        parts = line.split(":", 1)
                        if len(parts) == 2:
                            account_uri_result = parts[1].strip().strip("\"'")
                            break
        return {"changed": changed, "msg": msg, "account_uri": account_uri_result}

    if state == "present":
        # Build present command
        cmd = cmd_base + ["--state", "present"]
        if allow_creation == False:
            cmd.append("--no-allow-creation")
        if terms_agreed == True:
            cmd.append("--terms-agreed")
        for c in contact:
            cmd.extend(["--contact", c])

        # Account key input
        if account_key_src != None:
            if not ctx.file_exists(account_key_src):
                fail("account_key_src file does not exist: " + account_key_src)
            cmd.extend(["--account-key", account_key_src])
        else:
            # Compute deterministic temp path (avoid import)
            acc = 0
            for ch in account_key_content:
                acc = (acc * 31 + ord(ch)) % 1000000007
            temp_path = "/tmp/.acme_account_key_" + str(acc % 100000)[:5]
            ctx.file_write(temp_path, account_key_content, "0600")
            cmd.extend(["--account-key", temp_path])

        # External account binding
        if external_account_binding != None:
            for k in ["kid", "alg", "key"]:
                cmd.extend(["--eab-" + k, external_account_binding[k]])

        probe = ctx.run(cmd + ["--check"], mutates=False)
        if probe.rc == 0:
            if probe.stdout.strip():
                account_uri_result = probe.stdout.strip()
            return {"changed": False, "msg": "account already exists", "account_uri": account_uri_result}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create or update account", "account_uri": account_uri_result}
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would create or update account", "account_uri": account_uri_result}
            if res.rc != 0:
                fail("failed to create or update account: " + res.stderr)
            if res.stdout.strip():
                account_uri_result = res.stdout.strip()
            return {"changed": True, "msg": "account created or updated", "account_uri": account_uri_result}

    if state == "changed_key":
        # Parse new account key input
        if new_account_key_src != None:
            if not ctx.file_exists(new_account_key_src):
                fail("new_account_key_src file does not exist: " + new_account_key_src)
            cmd_key = ["--new-account-key", new_account_key_src]
        else:
            acc = 0
            for ch in new_account_key_content:
                acc = (acc * 31 + ord(ch)) % 1000000007
            temp_path = "/tmp/.acme_new_account_key_" + str(acc % 100000)[:5]
            ctx.file_write(temp_path, new_account_key_content, "0600")
            cmd_key = ["--new-account-key", temp_path]

        # Ensure account exists before key change
        probe = ctx.run(cmd_base + ["--state", "present", "--check"], mutates=False)
        if probe.rc != 0:
            fail("account does not exist for key change")
        # Extract current account URI
        if probe.stdout.strip():
            account_uri_result = probe.stdout.strip()

        # Perform key change
        cmd = cmd_base + ["--state", "changed_key"] + cmd_key
        if new_account_key_passphrase != None:
            cmd.extend(["--new-account-key-passphrase", new_account_key_passphrase])

        if ctx.check_mode:
            return {"changed": True, "msg": "would change account key", "account_uri": account_uri_result}
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would change account key", "account_uri": account_uri_result}
        if res.rc != 0:
            fail("failed to change account key: " + res.stderr)
        return {"changed": True, "msg": "account key changed", "account_uri": account_uri_result}

    fail("unsupported state: " + state)
