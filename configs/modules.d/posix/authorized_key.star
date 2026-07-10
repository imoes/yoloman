def main(ctx, params):
    user = params["user"]
    key = params["key"]
    path = params.get("path", None)
    manage_dir = params.get("manage_dir", True)
    state = params.get("state", "present")
    key_options = params.get("key_options", None)
    exclusive = params.get("exclusive", False)
    comment = params.get("comment", None)
    follow = params.get("follow", False)
    validate_certs = params.get("validate_certs", True)

    # Validate state
    if state not in ("present", "absent"):
        fail("invalid state: must be 'present' or 'absent'")

    # Handle URL keys
    if key.startswith("http"):
        # In check_mode, assume fetch would succeed
        if ctx.check_mode:
            fetched_key = key
        else:
            # Use curl to fetch the key
            curl_opts = ["curl", "-s", "-L"]
            if not validate_certs:
                curl_opts.append("-k")
            curl_opts.append(key)
            res = ctx.run(curl_opts)
            if res.rc != 0:
                fail("failed to fetch key from " + key + ": " + res.stderr)
            fetched_key = res.stdout
        key = fetched_key

    # Parse keys into list, skipping blank lines and comments
    key_lines = key.splitlines()
    new_keys = []
    for line in key_lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            new_keys.append(stripped)

    # Determine authorized_keys file path
    keysfile = ""
    if path == None:
        # Check if user exists
        res = ctx.run(["id", user])
        if res.rc != 0:
            if ctx.check_mode:
                # In check_mode, assume path will be created
                keysfile = "~/.ssh/authorized_keys"
            else:
                fail("user " + user + " does not exist")
        else:
            # Get home directory
            res = ctx.run(["getent", "passwd", user])
            if res.rc != 0:
                fail("failed to get user info for " + user)
            pwd_entry = res.stdout.split(":")
            if len(pwd_entry) < 6:
                fail("invalid passwd entry for " + user)
            homedir = pwd_entry[5]
            sshdir = homedir + "/.ssh"
            keysfile = sshdir + "/authorized_keys"
    else:
        keysfile = path

    # Read existing authorized_keys content
    existing_content = ""
    if ctx.file_exists(keysfile):
        existing_content = ctx.file_read(keysfile)

    # Parse existing keys
    existing_keys = {}
    valid_types = [
        "ssh-rsa", "ssh-dss", "ssh-ed25519", "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com", "ssh-xmss@openssh.com",
        "sk-ssh-ed25519-cert-v01@openssh.com", "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com",
        "ssh-xmss-cert-v01@openssh.com", "ssh-rsa-cert-v01@openssh.com",
        "ssh-dss-cert-v01@openssh.com", "ecdsa-sha2-nistp256-cert-v01@openssh.com",
        "ecdsa-sha2-nistp384-cert-v01@openssh.com", "ecdsa-sha2-nistp521-cert-v01@openssh.com",
        "rsa-sha2-256", "rsa-sha2-512", "rsa-sha2-256-cert-v01@openssh.com",
        "rsa-sha2-512-cert-v01@openssh.com"
    ]

    lines = existing_content.splitlines()
    for rank_index, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            continue

        parts = stripped.split(None, 2)
        if len(parts) < 2:
            continue

        key_type = parts[0]
        key_hash = parts[1]

        if key_type not in valid_types:
            continue

        # Extract options and comment
        options_str = ""
        comment = ""
        if len(parts) > 2:
            rest = parts[2]
            # Find the key hash in the rest
            idx = rest.find(key_hash)
            if idx >= 0:
                options_str = rest[:idx].strip()
                comment = rest[idx + len(key_hash):].strip()

        # Parse options into dict
        opts_dict = {}
        if options_str:
            for opt in options_str.split(","):
                if "=" in opt:
                    k, v = opt.split("=", 1)
                    opts_dict[k] = v
                else:
                    opts_dict[opt] = None

        existing_keys[key_hash] = (key_hash, key_type, opts_dict, comment)

    # Process new keys
    do_write = False
    keys_to_exist = []

    # Process each new key
    for rank_index, new_key in enumerate(new_keys):
        parts = new_key.split(None, 2)
        if len(parts) < 2:
            fail("invalid key format: " + new_key)

        key_type = parts[0]
        key_hash = parts[1]

        if key_type not in valid_types:
            fail("invalid key type in: " + new_key)

        # Parse options and comment
        options_str = ""
        comment = ""
        if len(parts) > 2:
            rest = parts[2]
            # Find the key hash in the rest
            idx = rest.find(key_hash)
            if idx >= 0:
                options_str = rest[:idx].strip()
                comment = rest[idx + len(key_hash):].strip()

        # Parse options into dict
        opts_dict = {}
        if options_str:
            for opt in options_str.split(","):
                if "=" in opt:
                    k, v = opt.split("=", 1)
                    opts_dict[k] = v
                else:
                    opts_dict[opt] = None

        # Apply key_options override
        if key_options != None:
            opts_dict = {}
            for opt in key_options.split(","):
                if "=" in opt:
                    k, v = opt.split("=", 1)
                    opts_dict[k] = v
                else:
                    opts_dict[opt] = None

        # Apply comment override if provided
        final_comment = comment
        if comment != None:
            final_comment = comment

        # Check if key already exists
        matched = False
        if key_hash in existing_keys:
            existing_entry = existing_keys[key_hash]
            existing_opts = existing_entry[2]
            existing_comment = existing_entry[3]

            # Compare options
            opts_eq = len(opts_dict) == len(existing_opts)
            for k, v in opts_dict.items():
                if k not in existing_opts or str(existing_opts[k]) != str(v):
                    opts_eq = False
                    break

            if key_type == existing_entry[1] and opts_eq and final_comment == existing_comment:
                matched = True

        if state == "present":
            keys_to_exist.append(key_hash)
            if not matched:
                existing_keys[key_hash] = (key_hash, key_type, opts_dict, final_comment)
                do_write = True
        elif state == "absent":
            if matched:
                # Delete the key from existing_keys
                # Using pop to avoid KeyError if key doesn't exist
                existing_keys.pop(key_hash, None)
                do_write = True

    # Handle exclusive mode
    if state == "present" and exclusive:
        to_remove = []
        for k in existing_keys:
            if k not in keys_to_exist:
                to_remove.append(k)
        for k in to_remove:
            existing_keys.pop(k, None)
        if to_remove:
            do_write = True

    # Apply changes
    if do_write:
        if ctx.check_mode:
            return {"changed": True, "msg": "would update authorized_keys for " + user}

        # Ensure directory exists if manage_dir == True
        if manage_dir:
            sshdir = ""
            if path == None:
                res = ctx.run(["getent", "passwd", user])
                if res.rc == 0:
                    pwd_entry = res.stdout.split(":")
                    if len(pwd_entry) >= 6:
                        homedir = pwd_entry[5]
                        sshdir = homedir + "/.ssh"
            else:
                sshdir = path.rsplit("/", 1)[0]

            if sshdir and not ctx.file_exists(sshdir):
                ctx.run(["mkdir", "-p", sshdir], mutates=True)
                ctx.run(["chmod", "700", sshdir], mutates=True)
            if sshdir:
                ctx.run(["chmod", "700", sshdir], mutates=True)

        # Serialize new content
        new_lines = []
        for key_hash in existing_keys:
            entry = existing_keys[key_hash]
            kh, kt, opts_dict, final_comment = entry

            # Build options string
            opt_parts = []
            for k, v in opts_dict.items():
                if v == None:
                    opt_parts.append(k)
                else:
                    opt_parts.append(k + "=" + str(v))
            opt_str = ",".join(opt_parts)
            if opt_str:
                opt_str += " "

            # Build final line
            line = opt_str + kt + " " + kh
            if final_comment:
                line += " " + final_comment
            new_lines.append(line)

        new_content = "\n".join(new_lines)
        if new_content and not new_content.endswith("\n"):
            new_content += "\n"

        # Write file
        ctx.file_write(keysfile, new_content, "0600")
        if not ctx.check_mode:
            ctx.run(["chown", user, keysfile], mutates=True)
            ctx.run(["chmod", "600", keysfile], mutates=True)

        return {"changed": True, "msg": "updated authorized_keys for " + user}

    return {"changed": False, "msg": "authorized_keys already up to date for " + user}
