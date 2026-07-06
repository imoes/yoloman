def main(ctx, params):
    src = params["src"]
    dest = params.get("dest")
    basedir = params.get("basedir")
    strip = params.get("strip", 0)
    remote_src = params.get("remote_src", False)
    backup = params.get("backup", False)
    binary = params.get("binary", False)
    ignore_whitespace = params.get("ignore_whitespace", False)
    state = params.get("state", "present")

    # Validate required parameters
    if dest == None and basedir == None:
        fail("one of dest or basedir is required")
    
    # Check src exists and is readable
    if not ctx.file_exists(src):
        fail("src " + src + " doesn't exist or not readable")
    
    # Check dest is writable if provided
    if dest != None and ctx.file_exists(dest):
        stat_dest = ctx.stat(dest)
        if stat_dest == None or not stat_dest.get("exists", False):
            fail("dest " + dest + " doesn't exist or not writable")
    
    # Check basedir exists if provided
    if basedir != None:
        stat_basedir = ctx.stat(basedir)
        if stat_basedir == None or not stat_basedir.get("exists", False) or not stat_basedir.get("is_dir", False):
            fail("basedir " + basedir + " doesn't exist")

    # Set default basedir
    if basedir == None:
        # Extract directory from dest path (without trailing slash handling)
        if dest.endswith('/'):
            basedir = dest[:-1]
        else:
            basedir = "/".join(dest.split("/")[:-1]) if "/" in dest else "."
    
    # Check patch binary exists
    res_patch = ctx.run(["which", "patch"])
    if res_patch.rc != 0:
        fail("patch command not found")

    # Build patch command options
    opts = [
        "patch",
        "--quiet",
        "--forward",
        "--batch",
        "--reject-file=-",
        "--strip=" + str(strip),
        "--directory='" + basedir + "'",
        "--input='" + src + "'"
    ]

    # Add dry-run for check mode
    if ctx.check_mode:
        # Use --check for BSD systems, otherwise --dry-run
        facts = ctx.facts()
        os_family = facts.get("os_family", "").lower()
        if os_family in ["openbsd", "netbsd", "freebsd"]:
            opts.append("--check")
        else:
            opts.append("--dry-run")

    # Add state-specific options
    if state == "absent":
        opts.append("--reverse")

    # Add other options
    if binary:
        opts.append("--binary")
    if ignore_whitespace:
        opts.append("--ignore-whitespace")
    if dest:
        opts.append("'" + dest + "'")
    if backup:
        opts.append("--backup --version-control=numbered")

    # Try to apply the patch
    res = ctx.run(opts, mutates=True)
    if res.skipped:
        # In check mode and would make changes
        return {"changed": True, "msg": "would apply patch"}

    if res.rc != 0:
        fail("patch failed: " + (res.stderr if res.stderr else res.stdout))

    return {"changed": True, "msg": "patch applied successfully"}
