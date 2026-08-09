def main(ctx, params):
    path = params["path"]
    size = params["size"]
    blocksize = params.get("blocksize")
    source = params.get("source", "/dev/zero")
    sparse = params.get("sparse", False)
    force = params.get("force", False)
    owner = params.get("owner")
    group = params.get("group")
    mode = params.get("mode")
    attributes = params.get("attributes")
    selevel = params.get("selevel")
    serole = params.get("serole")
    setype = params.get("setype")
    seuser = params.get("seuser")

    # Mutual exclusion check
    if sparse and force:
        fail("parameters values are mutually exclusive: force=true|sparse=true")

    # Parent directory must exist
    path_dir = path.rsplit("/", 1)[0] if "/" in path else "."
    if not ctx.file_exists(path_dir):
        fail("parent directory of the file must exist prior to run this module")

    # Determine blocksize if not provided
    if blocksize == None:
        statvfs = ctx.stat("/" if path_dir == "." else path_dir)
        if statvfs == None:
            fail("could not stat filesystem for blocksize detection")
        # Use f_frsize (fragment size) if available, otherwise fallback to f_bsize
        blocksize = str(statvfs.get("blocksize", 4096))

    # Helper: parse size string with unit
    SIZE_UNITS = {
        "B": 1,
        "kB": 1000, "KB": 1000, "KiB": 1024, "K": 1024, "k": 1024,
        "MB": 1000000, "mB": 1000000, "MiB": 1048576, "M": 1048576, "m": 1048576,
        "GB": 1000000000, "gB": 1000000000, "GiB": 1073741824, "G": 1073741824, "g": 1073741824,
        "TB": 1000000000000, "tB": 1000000000000, "TiB": 1099511627776, "T": 1099511627776, "t": 1099511627776,
        "PB": 1000000000000000, "pB": 1000000000000000, "PiB": 1125899906842624, "P": 1125899906842624, "p": 1125899906842624,
        "EB": 1000000000000000000, "eB": 1000000000000000000, "EiB": 1152921504606846976, "E": 1152921504606846976, "e": 1152921504606846976,
        "ZB": 1000000000000000000000, "zB": 1000000000000000000000, "ZiB": 1180591620717411303424, "Z": 1180591620717411303424, "z": 1180591620717411303424,
        "YB": 1000000000000000000000000, "yB": 1000000000000000000000000, "YiB": 1208925819614629174706176, "Y": 1208925819614629174706176, "y": 1208925819614629174706176,
    }

    def parse_size_value(v):
        v = str(v)
        # Strip whitespace
        v = v.strip()
        # Extract numeric part and unit part
        numeric_end = 0
        for i in range(len(v)):
            c = v[i]
            if c.isdigit() or c == '.':
                numeric_end = i + 1
            else:
                break
        num_str = v[:numeric_end]
        unit = v[numeric_end:].strip()
        num_val = float(num_str)

        if unit == "":
            # No unit: treat as number of blocks
            blocks = int(round(num_val))
            # Blocksize already parsed, compute total
            return blocks, int(blocksize), blocks * int(blocksize)

        if unit not in SIZE_UNITS:
            fail("invalid size unit: %s. Supported: %s" % (unit, ", ".join(sorted(SIZE_UNITS))))

        total_bytes = int(round(num_val * SIZE_UNITS[unit]))
        # Determine best blocksize for dd
        def smart_blocksize(total, blk):
            if total % blk == 0:
                return blk
            # Try common block sizes
            for candidate in (1024, 1000, 512, 256, 128, 100, 64, 32, 16, 10, 8, 4, 2):
                if total % candidate == 0:
                    return candidate
            return 1

        block_size = smart_blocksize(total_bytes, int(blocksize))
        blocks = (total_bytes + block_size - 1) // block_size if total_bytes > 0 else 0
        # Adjust total to align
        rounded_bytes = blocks * block_size
        return blocks, block_size, rounded_bytes

    # Parse size and blocksize
    blocks, block_size, rounded_bytes = parse_size_value(size)

    # Parse blocksize separately
    _, _, _ = parse_size_value(blocksize)

    # Read current size
    current_stat = ctx.stat(path)
    initial_filesize = 0
    if current_stat != None:
        if current_stat["is_dir"]:
            fail("%s exists but is not a regular file" % path)
        initial_filesize = current_stat["size"]

    # Compute size diff
    size_diff = rounded_bytes - initial_filesize

    # Build dd command
    dd_bin = ctx.run(["which", "dd"], ok_codes=[0,1])
    if dd_bin.rc != 0:
        fail("dd command not found in PATH")

    dd_cmd = [dd_bin.stdout.strip(), "if=%s" % source, "of=%s" % path]

    # Determine dd parameters
    changed_needed = rounded_bytes != initial_filesize or force
    if not changed_needed:
        # Nothing to do
        result = {
            "changed": False,
            "msg": "file %s already has size %s" % (path, rounded_bytes),
            "data": {
                "path": path,
                "size_diff": size_diff,
                "filesize": {
                    "blocks": 0,
                    "blocksize": block_size,
                    "bytes": 0,
                    "iec": "0 B",
                    "si": "0 B"
                }
            }
        }
        # Apply file attributes (owner, group, mode, etc.) if needed
        file_args = {}
        if owner != None:
            file_args["owner"] = owner
        if group != None:
            file_args["group"] = group
        if mode != None:
            # Support symbolic mode parsing? Skip for now, fail if not octal
            if not (type(mode) == "string" and mode.isdigit() and len(mode) <= 4):
                fail("mode must be octal (e.g. '0644')")
            file_args["mode"] = int(mode, 8)
        if attributes != None:
            # Not implemented — just warn
            pass

        if len(file_args) > 0:
            # Apply attributes
            if owner != None:
                ctx.run(["chown", owner, path], mutates=False)
            if group != None:
                ctx.run(["chgrp", group, path], mutates=False)
            if mode != None:
                ctx.run(["chmod", mode, path], mutates=False)
        return result

    # Build dd options
    # Sparse: seek=blocks, count=0
    if sparse:
        seek = blocks
        count = 0
    elif force or current_stat == None:
        # Create new file: seek=0, count=blocks
        seek = 0
        count = blocks
    elif size_diff < 0:
        # Truncate: seek=blocks, count=0
        seek = blocks
        count = 0
    elif size_diff > 0:
        # Grow: seek after last block
        if initial_filesize > 0:
            seek = (initial_filesize // block_size) + 1
        else:
            seek = 0
        count = blocks - seek
    else:
        # Equal size but force is false — no change
        return {"changed": False, "msg": "file size already correct"}

    dd_cmd += ["bs=%s" % str(block_size), "seek=%s" % str(seek), "count=%s" % str(count)]

    # Human-readable size helpers
    def bytes_to_human(size, iec=False):
        unit = "B"
        for u in sorted(SIZE_UNITS, key=lambda x: SIZE_UNITS[x]):
            if size < SIZE_UNITS[u]:
                continue
            if iec:
                if "i" not in u or size / SIZE_UNITS[u] >= 1024:
                    continue
            else:
                if SIZE_UNITS[u] % 5 != 0 or size / SIZE_UNITS[u] >= 1000:
                    continue
            unit = u
        hsize = round(size / SIZE_UNITS[unit], 2)
        if unit == "B":
            hsize = int(hsize)
        # Capitalize first letter
        unit = unit[0].upper() + unit[1:]
        if unit == "KB":
            unit = "kB"
        return "%s %s" % (str(hsize), unit)

    # Execute command (unless check_mode)
    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "would resize %s from %d to %d bytes" % (path, initial_filesize, rounded_bytes)
        }

    res = ctx.run(dd_cmd, mutates=True)
    if res.rc != 0:
        fail("dd failed: " + res.stderr)

    # Verify final size
    final_stat = ctx.stat(path)
    if final_stat == None:
        fail("file %s does not exist after dd" % path)

    final_size = final_stat["size"]
    if final_size != rounded_bytes:
        fail("expected size %d bytes, got %d" % (rounded_bytes, final_size))

    # Update file attributes (owner, group, mode, attributes)
    # Only if present in params
    file_cmd = []
    if owner != None:
        file_cmd += ["chown", owner, path]
    if group != None:
        file_cmd += ["chgrp", group, path]
    if mode != None:
        # Convert to string if needed
        mode_str = str(mode)
        if mode_str.isdigit():
            file_cmd += ["chmod", mode_str, path]
    if len(file_cmd) > 0:
        ctx.run(file_cmd, mutates=True)

    # Build result
    filesize = {
        "blocks": blocks,
        "blocksize": block_size,
        "bytes": rounded_bytes,
        "iec": bytes_to_human(rounded_bytes, True),
        "si": bytes_to_human(rounded_bytes)
    }

    return {
        "changed": True,
        "msg": "resized %s to %s (%d bytes)" % (path, filesize["iec"], rounded_bytes),
        "data": {
            "cmd": " ".join(dd_cmd),
            "filesize": filesize,
            "size_diff": size_diff,
            "path": path
        }
    }
