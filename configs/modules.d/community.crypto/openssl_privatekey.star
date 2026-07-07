def main(ctx, params):
    path = params["path"]
    force = params.get("force", False)
    backup = params.get("backup", False)
    return_content = params.get("return_content", False)
    state = params.get("state", "present")
    format_opt = params.get("format", "auto_ignore")
    format_mismatch = params.get("format_mismatch", "regenerate")
    curve = params.get("curve")
    passphrase = params.get("passphrase")
    size = params.get("size", 4096)
    key_type = params.get("type", "RSA")
    attributes = params.get("attributes")
    group = params.get("group")
    owner = params.get("owner")
    mode = params.get("mode")

    # Validate key_type
    if key_type not in ["RSA", "DSA", "ECC"]:
        fail("Unsupported key type: " + key_type + ". Supported types: RSA, DSA, ECC")

    # Validate ECC curve
    if key_type == "ECC" and curve == None:
        fail("curve is required when type=ECC")
    if key_type != "ECC" and curve != None:
        fail("curve is only valid when type=ECC")

    # Validate format options
    if format_opt not in ["pkcs1", "pkcs8", "raw", "auto", "auto_ignore"]:
        fail("Invalid format: " + format_opt)
    if format_mismatch not in ["regenerate", "convert"]:
        fail("Invalid format_mismatch: " + format_mismatch)

    # Check if path directory exists
    slash_idx = path.rfind("/")
    if slash_idx != -1:
        dir_path = path[:slash_idx]
        if dir_path != "" and not ctx.file_exists(dir_path):
            fail("The directory " + dir_path + " does not exist or the file is not a directory")
    else:
        # Current directory always exists
        pass

    # Read existing key content if present
    existing_content = None
    if ctx.file_exists(path):
        existing_content = ctx.file_read(path)

    # Determine if regeneration or conversion is needed
    needs_regeneration = False
    needs_conversion = False
    existing_key_valid = False

    if existing_content != None and not force:
        # Heuristic: if key exists, assume valid unless parameters explicitly conflict
        if key_type == "ECC" and curve != None:
            needs_regeneration = True
        if key_type == "RSA" and size != 4096:
            needs_regeneration = True
        if passphrase != None:
            if existing_content.find("ENCRYPTED") == -1:
                needs_regeneration = True

        if not needs_regeneration and existing_content != None:
            existing_key_valid = True
    elif existing_content == None:
        needs_regeneration = True

    if not force and not needs_regeneration and existing_key_valid:
        if format_opt not in ["auto", "auto_ignore", None] and existing_content != None:
            if format_opt == "pkcs8" and existing_content.find("BEGIN PUBLIC KEY") > -1:
                needs_conversion = True

    # Backup existing file if needed
    backup_file = None
    if existing_content != None and (needs_regeneration or needs_conversion) and not ctx.check_mode:
        if backup:
            res = ctx.run(["date", "+%s"])
            if res.rc == 0:
                ts = res.stdout.strip()
            else:
                ts = "backup"
            backup_file = path + "." + ts
            ctx.run(["cp", "-p", path, backup_file], mutates=True)
            backup_file = backup_file

    # Perform action
    if state == "present":
        if not needs_regeneration and not needs_conversion:
            current_mode = None
            if ctx.file_exists(path):
                st = ctx.stat(path)
                if st != None:
                    current_mode = st.get("mode", None)
            changed = _ensure_file_attrs(ctx, path, mode, owner, group, attributes)
            if ctx.check_mode and (changed or needs_regeneration or needs_conversion):
                return {"changed": True, "msg": "would update attributes of existing key"}
            return {"changed": changed, "msg": "key already exists and attributes match", "size": size, "type": key_type, "curve": curve, "filename": path}

        if not ctx.check_mode:
            # Generate key using openssl CLI
            cmd = ["openssl", "genpkey"]
            if key_type == "RSA":
                cmd.extend(["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:" + str(size)])
            elif key_type == "DSA":
                cmd.extend(["-algorithm", "DSA", "-pkeyopt", "dsa_paramgen_bits:" + str(size)])
            elif key_type == "ECC":
                cmd.extend(["-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:" + curve])
            if passphrase != None:
                cmd.extend(["-aes-256-cbc", "-pass", "pass:" + passphrase])
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("failed to generate private key: " + res.stderr)

            key_content = res.stdout
            # Handle format conversion to PKCS8 if requested
            if format_opt == "pkcs8" and key_content != None:
                # Skip conversion if passphrase required
                if passphrase == None:
                    cmd2 = ["openssl", "pkcs8", "-topk8", "-nocrypt", "-inform", "PEM", "-outform", "PEM"]
                    res2 = ctx.run(cmd2, mutates=True)
                    if res2.rc != 0:
                        fail("failed to convert to PKCS8: " + res2.stderr)
                    key_content = res2.stdout

            ctx.file_write(path, key_content, "0600" if mode == None else None)
            _ensure_file_attrs(ctx, path, mode, owner, group, attributes)
            changed = True
        else:
            if needs_regeneration or needs_conversion or _needs_file_update(ctx, path, mode, owner, group, attributes):
                return {"changed": True, "msg": "would generate or update private key"}
            return {"changed": False, "msg": "key already exists and matches", "size": size, "type": key_type, "curve": curve, "filename": path}

        if return_content:
            res = ctx.run(["cat", path])
            return {"changed": True, "msg": "generated private key", "size": size, "type": key_type, "curve": curve, "filename": path, "privatekey": res.stdout}

        return {"changed": True, "msg": "generated private key", "size": size, "type": key_type, "curve": curve, "filename": path, "backup_file": backup_file}

    elif state == "absent":
        if ctx.file_exists(path):
            if not ctx.check_mode:
                ctx.run(["rm", "-f", path], mutates=True)
                return {"changed": True, "msg": "removed private key", "filename": path}
            else:
                return {"changed": True, "msg": "would remove private key", "filename": path}
        else:
            return {"changed": False, "msg": "private key does not exist", "filename": path}

    fail("unsupported state: " + state)


def _needs_file_update(ctx, path, mode, owner, group, attributes):
    st = ctx.stat(path)
    if st == None:
        return True
    if mode != None and st.get("mode", None) != None:
        current_mode_str = _mode_to_octal_str(st["mode"])
        if current_mode_str != mode:
            return True
    if owner != None:
        current_owner = str(st.get("uid", None))
        if current_owner != owner and st.get("uid", None) != None:
            return True
    if group != None:
        current_group = str(st.get("gid", None))
        if current_group != group and st.get("gid", None) != None:
            return True
    return False


def _ensure_file_attrs(ctx, path, mode, owner, group, attributes):
    changed = False
    if not ctx.check_mode:
        if mode != None:
            res = ctx.run(["chmod", mode, path], mutates=True)
            if res.rc != 0:
                fail("failed to set mode on " + path)
            changed = True
        if owner != None or group != None:
            owner_str = owner if owner != None else ""
            group_str = group if group != None else ""
            chown_cmd = ["chown"]
            if owner_str != "" and group_str != "":
                chown_cmd.append(owner_str + ":" + group_str)
            elif owner_str != "":
                chown_cmd.append(owner_str)
            else:
                chown_cmd.append(":" + group_str)
            chown_cmd.append(path)
            res = ctx.run(chown_cmd, mutates=True)
            if res.rc != 0:
                fail("failed to set ownership on " + path)
            changed = True
        if attributes != None:
            fail("setting file attributes with chattr is not supported in this Starlark module")
    return changed


def _mode_to_octal_str(mode_int):
    # Convert mode integer to 4-digit octal string, e.g., 33188 -> "0644"
    octal = ""
    tmp = mode_int
    for i in range(4):
        octal = str(tmp % 8) + octal
        tmp = tmp // 8
    return "0" + octal if len(octal) < 4 else octal
