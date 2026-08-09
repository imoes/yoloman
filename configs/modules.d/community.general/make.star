def main(ctx, params):
    chdir = params["chdir"]
    target = params.get("target")
    targets = params.get("targets")
    file_path = params.get("file")
    jobs = params.get("jobs")
    make_bin = params.get("make")
    params_dict = params.get("params")

    # Validate mutually exclusive options
    if target != None and targets != None:
        fail("target and targets are mutually exclusive")

    # Determine make binary
    make_path = make_bin
    if make_path == None:
        # Prefer gmake, fallback to make
        res = ctx.run(["which", "gmake"], mutates=False)
        if res.rc == 0:
            make_path = "gmake"
        else:
            res = ctx.run(["which", "make"], mutates=False)
            if res.rc != 0:
                fail("make binary not found")
            make_path = "make"

    # Build parameter list
    make_parameters = []
    if params_dict != None:
        for k in sorted(params_dict.keys()):
            v = params_dict.get(k)
            if v == None:
                make_parameters.append(k)
            else:
                make_parameters.append(k + "=" + str(v))

    # Build base command
    base_command = [make_path]
    if jobs != None:
        base_command.extend(["-j", str(jobs)])
    if file_path != None:
        base_command.extend(["-f", file_path])
    
    # Add target(s)
    if target != None:
        base_command.append(target)
    elif targets != None:
        base_command.extend(targets)
    else:
        # Default to first target (no target specified)
        pass
    
    # Add extra parameters
    base_command.extend(make_parameters)

    # Check if target is up to date using -q
    check_cmd = base_command + ["-q"]
    res = ctx.run(check_cmd, mutates=False, ok_codes=[0, 1, 2])
    
    if ctx.check_mode:
        # Dry run mode: predict whether change is needed
        changed = (res.rc != 0)
        return {"changed": changed, "msg": "would run make" if changed else "make target already up to date", "data": {
            "command": " ".join(base_command),
            "chdir": chdir,
            "target": target,
            "targets": targets,
            "params": params_dict,
            "file": file_path,
            "jobs": jobs
        }}
    
    # Actual run mode
    if res.rc == 0:
        # Target is up to date
        return {"changed": False, "msg": "make target already up to date", "data": {
            "command": " ".join(base_command),
            "chdir": chdir,
            "target": target,
            "targets": targets,
            "params": params_dict,
            "file": file_path,
            "jobs": jobs
        }}
    else:
        # Target needs to be built
        res = ctx.run(base_command, mutates=True, ok_codes=[0])
        if res.rc != 0:
            fail("make command failed: " + res.stderr)
        return {"changed": True, "msg": "make target executed successfully", "data": {
            "command": " ".join(base_command),
            "chdir": chdir,
            "target": target,
            "targets": targets,
            "params": params_dict,
            "file": file_path,
            "jobs": jobs
        }}
