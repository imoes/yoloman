def main(ctx, params):
    path = params["path"]
    size = params.get("size", 4096)
    force = params.get("force", False)
    state = params.get("state", "present")
    backup = params.get("backup", False)
    return_content = params.get("return_content", False)
    backend = params.get("select_crypto_backend", "auto")

    # Validate path directory exists
    path_dir = path.rsplit("/", 1)[0] if "/" in path else "."
    if path_dir == "":
        path_dir = "."
    stat_dir = ctx.stat(path_dir)
    if stat_dir == None or not stat_dir.get("is_dir", False):
        fail("The directory '" + path_dir + "' does not exist or the file is not a directory")

    # Backend selection
    if backend not in ("auto", "cryptography", "openssl"):
        fail("Invalid select_crypto_backend: " + backend)

    if state == "present":
        if backend == "auto":
            # Try openssl binary detection via which command
            openssl_bin = ctx.run(["which", "openssl"], mutates=False)
            can_use_openssl = openssl_bin.rc == 0
            if not can_use_openssl:
                fail("OpenSSL binary not found")
            backend = "openssl"
        elif backend == "cryptography":
            fail("The cryptography backend is not supported in the Starlark runtime")
        elif backend != "openssl":
            fail("Only the openssl backend is supported in the Starlark runtime")

        # Check if file exists and is valid
        existing_dhparam = None
        if ctx.file_exists(path):
            res_check = ctx.run(["openssl", "dhparam", "-check", "-noout", "-in", path], mutates=False)
            if res_check.rc == 0:
                # Parse size from verbose output
                res_verbose = ctx.run(["openssl", "dhparam", "-text", "-noout", "-in", path], mutates=False)
                if res_verbose.rc == 0:
                    output = res_verbose.stdout
                    lines = output.split("\n")
                    for line in lines:
                        # Look for "(XXXX bit)" pattern
                        if "(" in line and "bit)" in line:
                            # Find substring between ( and " bit)"
                            start_idx = 0
                            end_idx = 0
                            for i in range(len(line)):
                                if line[i] == "(":
                                    start_idx = i + 1
                                if line[i] == "b" and line[i+1] == "i" and line[i+2] == "t" and line[i+3] == ")" and i > start_idx:
                                    end_idx = i
                                    break
                            if start_idx > 0 and end_idx > start_idx:
                                num_str = line[start_idx:end_idx]
                                # Manual string-to-int conversion
                                val = 0
                                for c in num_str:
                                    if c < "0" or c > "9":
                                        fail("invalid digit in DH param size")
                                    val = val * 10 + ord(c) - ord("0")
                                existing_dhparam = val
                                break
                else:
                    existing_dhparam = size  # Assume correct if check passed but parsing failed
            else:
                existing_dhparam = None

        # Determine if regeneration needed
        regenerate = force or (existing_dhparam == None or existing_dhparam != size)

        if ctx.check_mode:
            result = {
                "changed": regenerate,
                "msg": "would regenerate" if regenerate else "already present",
                "size": size,
                "filename": path,
            }
            if backup:
                fail("backup option not supported in check_mode for Starlark runtime")
            if return_content and ctx.file_exists(path):
                result["dhparams"] = ctx.file_read(path)
            return result

        # Generate DH params if needed
        if regenerate:
            tmpsrc = "/tmp/dhparam_" + str(ctx.facts().get("hostname", "localhost"))
            # Attempt atomic write via temporary file
            res_gen = ctx.run(["openssl", "dhparam", "-out", tmpsrc, str(size)], mutates=True)
            if res_gen.rc != 0:
                fail("failed to generate DH params: " + res_gen.stderr)
            # Use mv for atomic move if possible
            res_move = ctx.run(["mv", "-T", tmpsrc, path], mutates=True)
            if res_move.rc != 0:
                # Fallback: rm target then mv
                ctx.run(["rm", "-f", path], mutates=True)
                res_move2 = ctx.run(["mv", tmpsrc, path], mutates=True)
                if res_move2.rc != 0:
                    fail("failed to move DH params file: " + res_move2.stderr)
            # Set file ownership and permissions if specified
            file_args = {}
            for key in ("owner", "group", "mode"):
                if params.get(key) != None:
                    file_args[key] = params[key]
            if file_args:
                if "owner" in file_args:
                    ctx.run(["chown", file_args["owner"], path], mutates=True)
                if "group" in file_args:
                    ctx.run(["chgrp", file_args["group"], path], mutates=True)
                if "mode" in file_args:
                    mode_str = str(file_args["mode"])
                    if mode_str.startswith("0"):
                        chmod_octal = mode_str
                    else:
                        fail("symbolic mode not supported in Starlark runtime")
                    ctx.run(["chmod", chmod_octal, path], mutates=True)

        # Prepare result
        result = {
            "changed": regenerate,
            "msg": "generated" if regenerate else "already present",
            "size": size,
            "filename": path,
        }
        if return_content and ctx.file_exists(path):
            result["dhparams"] = ctx.file_read(path)
        return result

    elif state == "absent":
        exists = ctx.file_exists(path)
        if ctx.check_mode:
            return {"changed": exists, "msg": "would remove" if exists else "already absent", "size": size, "filename": path}

        if exists:
            if backup:
                fail("backup option not supported in Starlark runtime")
            res_rm = ctx.run(["rm", "-f", path], mutates=True)
            if res_rm.rc != 0:
                fail("failed to remove DH params file: " + res_rm.stderr)
            return {"changed": True, "msg": "removed", "size": size, "filename": path}

        return {"changed": False, "msg": "already absent", "size": size, "filename": path}

    else:
        fail("unsupported state: " + state)
