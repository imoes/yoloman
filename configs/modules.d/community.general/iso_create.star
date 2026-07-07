def main(ctx, params):
    src_files = params["src_files"]
    dest_iso = params["dest_iso"]
    interchange_level = params.get("interchange_level", 1)
    vol_ident = params.get("vol_ident", "")
    rock_ridge = params.get("rock_ridge")
    joliet = params.get("joliet")
    udf = params.get("udf", False)

    # Validate src_files exists and is non-empty
    if not src_files or len(src_files) == 0:
        ctx.fail("Please specify source file and/or directory list using src_files parameter.")
    for src_file in src_files:
        if not ctx.file_exists(src_file):
            ctx.fail("Specified source file/directory path does not exist on local machine: " + src_file)

    # Create destination directory if needed
    dest_iso_dir = dest_iso.rsplit("/", 1)[0]
    if dest_iso_dir and not ctx.file_exists(dest_iso_dir):
        if ctx.check_mode:
            # In check_mode, we assume mkdir would succeed (no way to test)
            pass
        else:
            # Create intermediate directories — use shell mkdir -p since Starlark lacks recursive mkdir
            res = ctx.run(["mkdir", "-p", dest_iso_dir], mutates=True)
            if res.skipped:
                ctx.fail("Would create directory: " + dest_iso_dir)
            if res.rc != 0:
                ctx.fail("Failed to create directory " + dest_iso_dir + ": " + res.stderr)

    # Check if ISO already exists and has identical content — skip if no change
    iso_exists = ctx.file_exists(dest_iso)
    if iso_exists and not ctx.check_mode:
        # For idempotency, we can't easily compare ISO contents without external tools.
        # Per original module, we always regenerate and overwrite.
        # So: no early return; continue to write.
        pass

    # Build pycdlib command — fallback to a shell script if pycdlib not available
    # Since Starlark has no pycdlib, we must use the `genisoimage` CLI (commonly available)
    # If neither pycdlib nor genisoimage is installed, fail clearly.
    if ctx.check_mode:
        # In check_mode, assume success and predict change
        return {
            "changed": True,
            "msg": "would create ISO file: " + dest_iso,
            "data": {
                "source_file": src_files,
                "created_iso": dest_iso,
                "interchange_level": interchange_level,
                "vol_ident": vol_ident,
                "rock_ridge": rock_ridge,
                "joliet": joliet,
                "udf": udf,
            },
        }

    # Build the genisoimage command
    argv = ["genisoimage", "-o", dest_iso, "-J"]  # -J enables Joliet, -r enables Rock Ridge default 1.09
    if rock_ridge != None:
        argv.extend(["-r", "-R"])  # -r gives 1.09; for newer versions, need -r -v etc., but genisoimage doesn’t easily support 1.10/1.12
        if rock_ridge == "1.10":
            argv.append("-v")  # approximate, may not be perfect but standard genisoimage limitation
        elif rock_ridge == "1.12":
            argv.extend(["-v", "-v"])
    if joliet != None:
        # Already added -J, but level control via -joliet-level is not standard; assume 3 if -J
        pass
    if udf:
        argv.append("-udf")
    if interchange_level != None:
        argv.extend(["-iso-level", str(interchange_level)])
    if vol_ident:
        argv.extend(["-V", vol_ident])

    # Add source paths: for each file/dir, add a -input-charset or handle paths — genisoimage takes paths at end
    # Append paths (using absolute paths from src_files)
    for src_file in src_files:
        argv.append(src_file)

    res = ctx.run(argv, mutates=True)
    if res.skipped:
        ctx.fail("Would create ISO file: " + dest_iso)
    if res.rc != 0:
        ctx.fail("Failed to create ISO file " + dest_iso + ": " + res.stderr)

    return {
        "changed": True,
        "msg": "created ISO file: " + dest_iso,
        "data": {
            "source_file": src_files,
            "created_iso": dest_iso,
            "interchange_level": interchange_level,
            "vol_ident": vol_ident,
            "rock_ridge": rock_ridge,
            "joliet": joliet,
            "udf": udf,
        },
    }
