def main(ctx, params):
    # Extract and sanitize parameters
    keyid_raw = params["id"]
    data = params.get("data")
    file = params.get("file")
    url = params.get("url")
    keyserver = params.get("keyserver")
    verify = params.get("verify", True)
    force_update = params.get("force_update", False)
    keyring = params.get("keyring", "/etc/pacman.d/gnupg")
    state = params.get("state", "present")

    # Validate mutually exclusive sources
    sources = [data != None, file != None, url != None, keyserver != None]
    if sum(sources) > 1:
        fail("data, file, url, and keyserver are mutually exclusive")
    if state == "present" and sum(sources) == 0:
        fail("one of data, file, url, or keyserver is required when state is present")

    # Sanitize key ID
    keyid = keyid_raw.strip().upper().replace(" ", "").replace("0X", "")
    if len(keyid) != 40:
        fail("key ID is not full-length: %s" % keyid)
    for c in keyid:
        if c not in "0123456789ABCDEF":
            fail("key ID is not hexadecimal: %s" % keyid)

    # Check if key exists in keyring (read-only probe)
    res = ctx.run([
        "gpg", "--with-colons", "--batch", "--no-tty",
        "--no-default-keyring",
        "--keyring=%s/pubring.gpg" % keyring,
        "--list-keys", keyid
    ], mutates=False)
    key_present = res.rc == 0

    # Handle check_mode
    if ctx.check_mode:
        if state == "present":
            changed = (key_present and force_update) or not key_present
            return {"changed": changed, "msg": "key status would be updated" if changed else "key already in desired state"}
        elif state == "absent":
            if key_present:
                return {"changed": True, "msg": "would remove key"}
            return {"changed": False, "msg": "key not present, no action needed"}

    # State: absent
    if state == "absent":
        if key_present:
            res = ctx.run([
                "pacman-key", "--gpgdir", keyring, "--delete", keyid
            ], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would remove key"}
            if res.rc != 0:
                fail("failed to remove key: " + res.stderr)
            return {"changed": True, "msg": "key removed"}
        return {"changed": False, "msg": "key not present, no action needed"}

    # State: present
    if key_present and not force_update:
        return {"changed": False, "msg": "key already present and force_update is false"}

    # Prepare temp file if needed
    temp_file = None
    if data != None:
        temp_file = "/tmp/pacman_key_" + keyid + ".asc"
        ctx.file_write(temp_file, data)
    elif file != None:
        temp_file = file
    elif url != None:
        # Download URL content via curl
        res = ctx.run(["curl", "-sSL", url], mutates=False)
        if res.rc != 0:
            fail("failed to fetch key from " + url + ": " + res.stderr)
        data_downloaded = res.stdout
        temp_file = "/tmp/pacman_key_" + keyid + ".asc"
        ctx.file_write(temp_file, data_downloaded)
    elif keyserver != None:
        # Fetch key from keyserver
        res = ctx.run([
            "pacman-key", "--gpgdir", keyring, "--keyserver", keyserver, "--recv-keys", keyid
        ], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would add key from keyserver"}
        if res.rc != 0:
            fail("failed to receive key from " + keyserver + ": " + res.stderr)
        # Locally sign key (always done after adding)
        ctx.run([
            "pacman-key", "--gpgdir", keyring, "--lsign-key", keyid
        ], mutates=True)
        return {"changed": True, "msg": "key added and locally signed"}

    # Verify key if requested
    if verify:
        res = ctx.run([
            "gpg", "--with-colons", "--with-fingerprint",
            "--batch", "--no-tty", "--show-keys", temp_file
        ], mutates=False)
        if res.rc != 0:
            fail("failed to verify keyfile: " + res.stderr)
        # Parse key ID from output (fpr line)
        extracted = None
        for line in res.stdout.splitlines():
            if line.startswith("fpr:"):
                parts = line.split(":")
                if len(parts) > 9:
                    extracted = parts[9]
                    break
        if extracted == None:
            fail("could not extract key fingerprint from keyfile")
        if extracted != keyid:
            fail("key ID does not match. expected %s, got %s" % (keyid, extracted))

    # Add key to keyring
    res = ctx.run([
        "pacman-key", "--gpgdir", keyring, "--add", temp_file
    ], mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would add key"}
    if res.rc != 0:
        fail("failed to add key: " + res.stderr)

    # Locally sign key
    ctx.run([
        "pacman-key", "--gpgdir", keyring, "--lsign-key", keyid
    ], mutates=True)

    # Cleanup temp file if we created it
    if temp_file != None and temp_file.startswith("/tmp/pacman_key_"):
        ctx.file_write(temp_file, "")  # no-op in check_mode; real write in real mode is just to clear; then remove
        if not ctx.check_mode and ctx.file_exists(temp_file):
            # remove via run command
            ctx.run(["rm", "-f", temp_file], mutates=True)

    return {"changed": True, "msg": "key added and locally signed"}
