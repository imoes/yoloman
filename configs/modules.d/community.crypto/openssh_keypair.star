def main(ctx, params):
    path = params["path"]
    state = params.get("state", "present")
    key_type = params.get("type", "rsa")
    size = params.get("size")
    force = params.get("force", False)
    comment = params.get("comment")
    passphrase = params.get("passphrase")
    private_key_format = params.get("private_key_format", "auto")
    backend = params.get("backend", "auto")
    regenerate = params.get("regenerate", "partial_idempotence")

    # Validate supported options
    if state == "absent":
        # Handle removal
        if ctx.file_exists(path) or ctx.file_exists(path + ".pub"):
            if not ctx.check_mode:
                ctx.run(["rm", "-f", path, path + ".pub"])
            return {"changed": True, "msg": "removed keys"}
        return {"changed": False, "msg": "keys already absent"}

    # Key type validation (only RSA supported via ssh-keygen for simplicity)
    if key_type not in ("rsa", "dsa", "ed25519", "ecdsa", "rsa1"):
        fail("unsupported key type: %s" % key_type)

    # RSA1 is deprecated and often unsupported — fail early if requested
    if key_type == "rsa1":
        fail("rsa1 is deprecated and not supported by this module")

    # Backend selection
    use_cryptography = False
    if backend == "cryptography":
        use_cryptography = True
        fail("backend=cryptography is not supported; use opensshbin or auto")
    elif backend == "auto":
        # Prefer ssh-keygen (opensshbin) unless passphrase provided and no ssh-keygen
        res = ctx.run(["which", "ssh-keygen"])
        if passphrase != None and res.rc != 0:
            fail("passphrase requires backend=cryptography or opensshbin with ssh-keygen installed")
        use_cryptography = False

    # Check if keys already exist
    priv_exists = ctx.file_exists(path)
    pub_exists = ctx.file_exists(path + ".pub")

    # Regenerate logic
    must_regenerate = force or regenerate == "always"
    if priv_exists and not must_regenerate:
        # Probe existing key type and size via ssh-keygen
        probe = ctx.run(["ssh-keygen", "-l", "-f", path])
        if probe.rc == 0:
            # Output format: "4096 SHA256:xxxx comment (RSA)"
            line = probe.stdout.strip()
            if "\n" in line:
                line = line.splitlines()[0]
            parts = line.split()
            if len(parts) >= 3:
                existing_size = int(parts[0])
                existing_type_str = parts[-1].strip("()")
                # Map OpenSSH type strings to module types
                existing_type_map = {
                    "RSA": "rsa",
                    "DSA": "dsa",
                    "ED25519": "ed25519",
                    "ECDSA": "ecdsa"
                }
                existing_type = existing_type_map.get(existing_type_str, existing_type_str.lower())
                # Compare key type
                if existing_type == key_type:
                    # Compare size unless irrelevant (ed25519 fixed-size)
                    if key_type == "ed25519" or (existing_size == size) or size == None:
                        # Check passphrase match if requested
                        if passphrase == None:
                            must_regenerate = False
                        else:
                            # Try to read key with passphrase
                            test = ctx.run(["ssh-keygen", "-y", "-P", passphrase, "-f", path])
                            if test.rc == 0:
                                must_regenerate = False
                            else:
                                must_regenerate = True
                    else:
                        must_regenerate = True
                else:
                    must_regenerate = True
            else:
                must_regenerate = True
        else:
            must_regenerate = True

    # If regeneration required and not in check_mode, generate new keys
    if must_regenerate:
        args = ["ssh-keygen", "-t", key_type, "-f", path, "-N", "" if passphrase == None else passphrase]
        if key_type != "ed25519" and size != None:
            args.extend(["-b", str(size)])
        if comment != None:
            args.extend(["-C", comment])
        # Run generation
        gen_res = ctx.run(args, mutates=True)
        if gen_res.skipped:
            return {"changed": True, "msg": "would regenerate keypair"}
        if gen_res.rc != 0:
            fail("failed to generate key: " + gen_res.stderr)

        # Set file attributes if needed (owner, group, mode, SELinux)
        file_args = {
            "path": path,
            "owner": params.get("owner"),
            "group": params.get("group"),
            "mode": params.get("mode"),
            "seuser": params.get("seuser"),
            "serole": params.get("serole"),
            "setype": params.get("setype"),
            "selevel": params.get("selevel")
        }
        # Apply attributes to private key
        _apply_file_attrs(ctx, file_args, path)
        # Apply same attributes to public key
        file_args["path"] = path + ".pub"
        _apply_file_attrs(ctx, file_args, path + ".pub")

        # Gather return data: fingerprint, public key
        fp_res = ctx.run(["ssh-keygen", "-l", "-f", path])
        fp_line = fp_res.stdout.strip()
        if "\n" in fp_line:
            fp_line = fp_line.splitlines()[0]
        fingerprint = ""
        fp_parts = fp_line.split()
        if len(fp_parts) > 1:
            fingerprint = fp_parts[1]

        pub_res = ctx.run(["cat", path + ".pub"])
        public_key = ""
        if pub_res.rc == 0 and len(pub_res.stdout.strip()) > 0:
            pub_parts = pub_res.stdout.strip().split()
            if len(pub_parts) > 0:
                public_key = pub_parts[0]

        return {"changed": True, "msg": "generated new keypair", "data": {
            "size": size if size != None else (4096 if key_type == "rsa" else 256),
            "type": key_type,
            "filename": path,
            "fingerprint": fingerprint,
            "public_key": public_key,
            "comment": comment if comment != None else ""
        }}

    # No regeneration needed — update file attributes (comment/permissions only)
    changed_files = []
    file_args = {
        "path": path,
        "owner": params.get("owner"),
        "group": params.get("group"),
        "mode": params.get("mode"),
        "seuser": params.get("seuser"),
        "serole": params.get("serole"),
        "setype": params.get("setype"),
        "selevel": params.get("selevel")
    }
    if _apply_file_attrs(ctx, file_args.copy(), path):
        changed_files.append(path)
    if _apply_file_attrs(ctx, dict(file_args, path=path + ".pub"), path + ".pub"):
        changed_files.append(path + ".pub")

    # If comment differs and pub key exists, update comment using ssh-keygen
    if comment != None and pub_exists:
        # Read current comment (last field in public key file line)
        current_pub = ctx.file_read(path + ".pub").strip()
        if len(current_pub) > 0:
            current_parts = current_pub.split()
            current_comment = ""
            if len(current_parts) >= 3:
                current_comment = current_parts[2]
            if current_comment != comment:
                update_res = ctx.run(["ssh-keygen", "-c", "-f", path, "-C", comment, "-P", "" if passphrase == None else passphrase])
                if update_res.rc != 0:
                    fail("failed to update comment: " + update_res.stderr)
                changed_files.append(path + ".pub")

    if len(changed_files) > 0:
        return {"changed": True, "msg": "updated file attributes"}
    return {"changed": False, "msg": "keys already exist and match requested parameters"}


def _apply_file_attrs(ctx, args, path):
    # Apply owner/group/mode/SELinux attributes to a file
    changed = False
    stat = ctx.stat(path)
    if stat == None:
        return False

    # Owner
    if args.get("owner") != None:
        owner_uid = _resolve_user(ctx, args["owner"])
        if owner_uid != None and str(stat.get("uid", -1)) != str(owner_uid):
            if not ctx.check_mode:
                ctx.run(["chown", str(owner_uid), path])
            changed = True

    # Group
    if args.get("group") != None:
        group_gid = _resolve_group(ctx, args["group"])
        if group_gid != None and str(stat.get("gid", -1)) != str(group_gid):
            if not ctx.check_mode:
                ctx.run(["chgrp", str(group_gid), path])
            changed = True

    # Mode
    if args.get("mode") != None:
        mode_str = str(args["mode"])
        if mode_str.isdigit():
            # Convert decimal string to octal-style string for chmod
            mode_val = int(mode_str)
            if mode_val < 8:
                mode_octal = "000" + str(mode_val)
            elif mode_val < 64:
                mode_octal = "00" + str(mode_val)
            elif mode_val < 512:
                mode_octal = "0" + str(mode_val)
            else:
                mode_octal = str(mode_val)
        else:
            # Symbolic mode not supported
            fail("symbolic mode is not supported in this Starlark translation")

        current_mode = ""
        mode_oct = stat["mode"]
        if mode_oct != None:
            current_mode = "%o" % mode_oct
            # Normalize to 3 digits
            current_mode = current_mode.zfill(3)
        if current_mode != mode_octal.lstrip("0"):
            if not ctx.check_mode:
                ctx.run(["chmod", mode_octal.lstrip("0") if mode_octal.lstrip("0") != "" else "0", path])
            changed = True

    # SELinux attributes (ignored if not supported — ctx does not expose them)
    # Placeholder: in real implementation, use chcon or semanage if available
    if args.get("setype") != None or args.get("seuser") != None:
        pass  # Not implemented; skip to maintain correctness

    return changed


def _resolve_user(ctx, username):
    # Resolve username to UID; return None if not found
    if username.isdigit():
        return int(username)
    res = ctx.run(["id", "-u", username])
    if res.rc == 0:
        return int(res.stdout.strip())
    return None


def _resolve_group(ctx, groupname):
    # Resolve groupname to GID; return None if not found
    if groupname.isdigit():
        return int(groupname)
    res = ctx.run(["getent", "group", groupname])
    if res.rc == 0 and len(res.stdout.strip()) > 0:
        parts = res.stdout.strip().split(":")
        if len(parts) >= 3:
            return int(parts[2])
    return None
