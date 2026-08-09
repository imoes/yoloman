def main(ctx, params):
    # State aliases mapping
    present_states = ["present", "emerged", "installed", "latest"]
    absent_states = ["absent", "removed", "unmerged"]
    
    # Required params
    packages = params.get("package", [])
    state = params.get("state", "present")
    sync_mode = params.get("sync")
    depclean = params.get("depclean", False)
    
    # Validation: at least one of package, sync, or depclean must be specified
    if len(packages) == 0 and sync_mode == None and depclean == False:
        fail("one of package, sync, or depclean is required")
    
    # Validate state choices
    if state not in present_states and state not in absent_states:
        fail("invalid state: " + state + " (must be one of: " + ", ".join(present_states + absent_states) + ")")
    
    # Validate mutually exclusive options
    nodeps = params.get("nodeps", False)
    onlydeps = params.get("onlydeps", False)
    if nodeps == True and onlydeps == True:
        fail("nodeps and onlydeps are mutually exclusive")
    
    quiet = params.get("quiet", False)
    verbose = params.get("verbose", False)
    if quiet == True and verbose == True:
        fail("quiet and verbose are mutually exclusive")
    
    quietbuild = params.get("quietbuild", False)
    if quietbuild == True and verbose == True:
        fail("quietbuild and verbose are mutually exclusive")
    
    quietfail = params.get("quietfail", False)
    if quietfail == True and verbose == True:
        fail("quietfail and verbose are mutually exclusive")
    
    # Sync repositories if requested
    if sync_mode != None and sync_mode != "no":
        # Check if portage is available
        res = ctx.run(["which", "emerge"])
        if res.rc != 0:
            fail("emerge not found on system")
        
        # Sync
        if sync_mode == "web":
            res = ctx.run(["which", "emerge-webrsync"])
            if res.rc != 0:
                fail("emerge-webrsync not found")
            sync_cmd = ["emerge-webrsync", "--quiet"]
        else:
            sync_cmd = ["emerge", "--sync", "--quiet", "--ask=n"]
        
        res = ctx.run(sync_cmd)
        if res.rc != 0:
            fail("could not sync package repositories: " + res.stderr)
        
        # If no package specified, exit after sync
        if len(packages) == 0:
            return {"changed": False, "msg": "Sync successfully finished."}
    
    # Check if packages are already in desired state
    if len(packages) > 0:
        # Determine if packages are present or absent
        found_change_needed = False
        for pkg in packages:
            # Use emerge --pretend to check if package would be emerged
            res = ctx.run(["emerge", "--pretend", "--quiet", pkg])
            would_install = res.rc != 0
            
            if state in present_states and would_install == True:
                found_change_needed = True
                break
            elif state in absent_states and res.rc == 0:
                # Package exists if emerge --pretend succeeds for unmerge
                found_change_needed = True
                break
        
        if found_change_needed == False:
            # All packages already in desired state
            if state in present_states:
                return {"changed": False, "msg": "Packages already present."}
            else:
                return {"changed": False, "msg": "Packages already absent."}
    
    # Check mode: predict changes without executing
    if ctx.check_mode == True:
        msg = ""
        if state in present_states:
            msg = "Packages would be installed."
        elif state in absent_states:
            msg = "Packages would be removed."
        elif depclean == True:
            msg = "Depclean would be performed."
        return {"changed": True, "msg": msg}
    
    # Build emerge command arguments
    args = ["--ask=n"]
    
    # State-specific flags
    if state == "latest":
        args.append("--update")
    
    # Boolean flags
    flag_map = {
        "update": "--update",
        "deep": "--deep",
        "newuse": "--newuse",
        "changed_use": "--changed-use",
        "oneshot": "--oneshot",
        "noreplace": "--noreplace",
        "nodeps": "--nodeps",
        "onlydeps": "--onlydeps",
        "quiet": "--quiet",
        "verbose": "--verbose",
        "getbinpkgonly": "--getbinpkgonly",
        "getbinpkg": "--getbinpkg",
        "usepkgonly": "--usepkgonly",
        "usepkg": "--usepkg",
        "keepgoing": "--keep-going",
        "quietbuild": "--quiet-build",
        "quietfail": "--quiet-fail",
    }
    
    for flag, arg in flag_map.items():
        if params.get(flag, False) == True:
            args.append(arg)
    
    # Value-based flags
    value_flags = {
        "jobs": ("--jobs", None),
        "loadavg": ("--load-average", None),
        "backtrack": ("--backtrack", None),
        "withbdeps": ("--with-bdeps", lambda v: "y" if v else "n"),
    }
    
    for flag, (arg, transform) in value_flags.items():
        val = params.get(flag)
        if val != None:
            if transform != None:
                args.extend([arg, transform(val)])
            else:
                if val == 0 or val == 0.0:
                    args.append(arg)
                else:
                    args.extend([arg, str(val)])
    
    # Execute command based on state
    if depclean == True:
        # Depclean command
        if len(packages) > 0:
            # Validate state for depclean with packages
            if state not in absent_states:
                fail("depclean can only be used with package when the state is one of: " + ", ".join(absent_states))
        
        depclean_cmd = ["emerge", "--depclean"] + args + packages
        res = ctx.run(depclean_cmd)
        if res.rc != 0:
            fail("depclean failed: " + res.stderr)
        
        # Parse output for removed count
        removed = 0
        for line in res.stdout.split("\n"):
            if line.startswith("Number removed:"):
                parts = line.split(":")
                removed = int(parts[1].strip())
        
        changed = removed > 0
        msg = "Depclean completed."
        return {"changed": changed, "msg": msg, "data": {"removed": removed}}
    
    elif state in present_states:
        # Emerge command
        emerge_cmd = ["emerge"] + args + packages
        res = ctx.run(emerge_cmd)
        if res.rc != 0:
            fail("Packages not installed: " + res.stderr)
        
        # Check for SSH error with PORTAGE_BINHOST
        if (params.get("usepkgonly") == True or params.get("getbinpkg") == True or params.get("getbinpkgonly") == True) and "Permission denied (publickey)." in res.stderr:
            fail("Please check your PORTAGE_BINHOST configuration in make.conf and your SSH authorized_keys file")
        
        # Determine change status and message
        changed = False
        msg = "No packages installed."
        
        for line in res.stdout.split("\n"):
            if "Emerging (binary )" in line or line.startswith(">"):
                changed = True
                msg = "Packages installed."
                break
        
        return {"changed": changed, "msg": msg}
    
    elif state in absent_states:
        # Unmerge command
        unmerge_cmd = ["emerge", "--unmerge"] + args + packages
        res = ctx.run(unmerge_cmd)
        if res.rc != 0:
            fail("Packages not removed: " + res.stderr)
        
        return {"changed": True, "msg": "Packages removed."}
    
    return {"changed": False, "msg": "No action performed."}
