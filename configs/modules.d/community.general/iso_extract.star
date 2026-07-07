def main(ctx, params):
    image = params["image"]
    dest = params["dest"]
    files = params["files"]
    force = params.get("force", True)
    executable = params.get("executable", "7z")

    # Check required paths exist
    if not ctx.file_exists(dest):
        fail("Directory '" + dest + "' does not exist")
    if not ctx.file_exists(image):
        fail("ISO image '" + image + "' does not exist")

    # Determine if we can use 7z
    res = ctx.run([executable, "--help"], mutates=False, ok_codes=[0, 1])
    use_7z = res.rc == 0

    if not use_7z and params.get("executable") != None:
        fail("Executable '" + executable + "' is not found on the system, and fallback to mount not supported in Starlark")

    # Build list of files to extract (skip existing ones if force=False)
    extract_files = []
    for f in files:
        dest_file = dest + "/" + f.split("/")[-1]
        if force or not ctx.file_exists(dest_file):
            extract_files.append(f)

    if not extract_files:
        return {"changed": False, "msg": "All files already present", "files": []}

    # Create temp dir
    tmp_dir = ctx.run(["mktemp", "-d"], mutates=False).stdout.strip()
    if not tmp_dir:
        fail("Failed to create temporary directory")

    # Extract with 7z
    cmd = [executable, "x", image, "-o" + tmp_dir] + extract_files
    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("Failed to extract ISO image '" + image + "' to '" + tmp_dir + "': " + res.stderr)

    changed = False
    extracted_files = []

    for f in extract_files:
        tmp_src = tmp_dir + "/" + f
        if not ctx.file_exists(tmp_src):
            fail("Failed to extract '" + f + "' from ISO image")

        src_checksum = ctx.run(["sha1sum", tmp_src], mutates=False).stdout.split()[0]
        dest_file = dest + "/" + f.split("/")[-1]

        if ctx.file_exists(dest_file):
            dest_checksum = ctx.run(["sha1sum", dest_file], mutates=False).stdout.split()[0]
        else:
            dest_checksum = None

        extracted_files.append({
            "checksum": src_checksum,
            "dest": dest_file,
            "src": f,
        })

        if src_checksum != dest_checksum:
            if not ctx.check_mode:
                content = ctx.file_read(tmp_src)
                ctx.file_write(dest_file, content, mode="0644")
            changed = True

    # Cleanup temp dir
    ctx.run(["rm", "-rf", tmp_dir], mutates=True)

    if changed:
        msg = "Extracted " + str(len(extract_files)) + " file(s)"
    else:
        msg = "All files already in desired state"

    return {"changed": changed, "msg": msg, "files": extracted_files}
