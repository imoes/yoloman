def main(ctx, params):
    src = params["src"]
    dest = params["dest"]
    mode = params.get("mode", "push")
    archive = params.get("archive", True)
    checksum = params.get("checksum", False)
    compress = params.get("compress", True)
    existing_only = params.get("existing_only", False)
    dirs = params.get("dirs", False)
    delete = params.get("delete", False)
    partial = params.get("partial", False)
    delay_updates = params.get("delay_updates", True)
    verify_host = params.get("verify_host", False)
    ssh_connection_multiplexing = params.get("ssh_connection_multiplexing", False)
    private_key = params.get("private_key")
    rsync_path = params.get("rsync_path")
    dest_port = params.get("dest_port")
    rsync_timeout = params.get("rsync_timeout", 0)
    link_dest = params.get("link_dest")
    rsync_opts = params.get("rsync_opts", [])
    
    # Handle archive-derived defaults
    recursive = params.get("recursive")
    links = params.get("links")
    perms = params.get("perms")
    times = params.get("times")
    owner = params.get("owner")
    group = params.get("group")

    # Determine rsync binary
    res = ctx.run(["which", "rsync"])
    if res.rc != 0:
        fail("rsync not found on system")
    rsync_bin = res.stdout.strip()
    
    # Build command
    cmd = [rsync_bin]
    
    # Delay updates
    if delay_updates:
        cmd.append("--delay-updates")
        cmd.append("-F")
    
    # Compression
    if compress:
        cmd.append("--compress")
    
    # Timeout
    if rsync_timeout > 0:
        cmd.append("--timeout=" + str(rsync_timeout))
    
    # Dry-run for check mode
    if ctx.check_mode:
        cmd.append("--dry-run")
    
    # Delete option
    if delete:
        cmd.append("--delete-after")
    
    # Existing only
    if existing_only:
        cmd.append("--existing")
    
    # Checksum
    if checksum:
        cmd.append("--checksum")
    
    # Copy links
    if params.get("copy_links", False):
        cmd.append("--copy-links")
    
    # Archive mode handling
    if archive:
        cmd.append("--archive")
        if recursive == False:
            cmd.append("--no-recursive")
        if links == False:
            cmd.append("--no-links")
        if perms == False:
            cmd.append("--no-perms")
        if times == False:
            cmd.append("--no-times")
        if owner == False:
            cmd.append("--no-owner")
        if group == False:
            cmd.append("--no-group")
    else:
        if recursive == True:
            cmd.append("--recursive")
        if links == True:
            cmd.append("--links")
        if perms == True:
            cmd.append("--perms")
        if times == True:
            cmd.append("--times")
        if owner == True:
            cmd.append("--owner")
        if group == True:
            cmd.append("--group")
    
    # Dirs only (non-recursive)
    if dirs:
        cmd.append("--dirs")
    
    # Rsync protocol check
    src_rsync = src.startswith("rsync://")
    dest_rsync = dest.startswith("rsync://")
    if src_rsync and dest_rsync:
        fail("either src or dest must be localhost for rsync protocol")
    
    # SSH configuration for file transfers
    if not src_rsync and not dest_rsync:
        ssh_cmd = [ctx.run(["which", "ssh"]).stdout.strip()]
        if not ssh_connection_multiplexing:
            ssh_cmd.extend(["-S", "none"])
        if private_key != None:
            ssh_cmd.extend(["-i", private_key])
        if dest_port != None:
            ssh_cmd.extend(["-o", "Port=" + str(dest_port)])
        if not verify_host:
            ssh_cmd.extend(["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"])
        ssh_str = " ".join(ssh_cmd)
        cmd.append("--rsh=" + ssh_str)
    
    # Rsync path
    if rsync_path != None:
        cmd.append("--rsync-path=" + rsync_path)
    
    # Additional rsync options
    if rsync_opts != None:
        for opt in rsync_opts:
            if opt == "":
                ctx.run(["echo", "WARNING: empty string in rsync_opts is deprecated"]) 
            cmd.append(opt)
    
    # Partial
    if partial:
        cmd.append("--partial")
    
    # Link destination
    if link_dest != None and len(link_dest) > 0:
        cmd.append("-H")
        cmd.append("-vv")
        for ld in link_dest:
            # Expand user path
            expanded_ld = ld
            if ld.startswith("~"):
                expanded_ld = ld.replace("~", "/root", 1)  # Approximation
            # Check for subdirectory hardlinking
            if dest.startswith(expanded_ld):
                fail("Hardlinking into a subdirectory of the source would cause recursion. " + expanded_ld + " and " + dest)
            cmd.append("--link-dest=" + ld)
    
    # Output format for change detection
    changed_marker = "<<CHANGED>>"
    cmd.append("--out-format=" + changed_marker + "%i %n%L")
    
    # Append source and destination
    cmd.append(src)
    cmd.append(dest)
    
    # Execute rsync command
    res = ctx.run(cmd, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would synchronize " + src + " to " + dest}
    if res.rc != 0:
        fail("rsync failed: " + res.stderr)
    
    # Parse output for changes
    out = res.stdout
    changed = (changed_marker + ".") not in out
    out_clean = out.replace(changed_marker, "")
    out_lines = out_clean.split("\n")
    out_lines = [line for line in out_lines if line != ""]
    
    return {"changed": changed, "msg": out_clean, "data": {"stdout_lines": out_lines}}
