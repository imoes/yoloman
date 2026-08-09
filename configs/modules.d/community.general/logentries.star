def main(ctx, params):
    path = params["path"]
    state = params.get("state", "present")
    name = params.get("name")
    logtype = params.get("logtype")

    le_path = "/usr/local/bin/le"
    if not ctx.file_exists(le_path):
        fail("le binary not found at " + le_path)

    # Handle multiple log files
    logs = [p.strip() for p in path.split(",") if p.strip()]
    if not logs:
        fail("no log paths provided")

    # Determine action based on state aliases
    if state in ["present", "followed"]:
        # Follow logs
        followed = False
        for log in logs:
            # Check if already followed
            res = ctx.run([le_path, "followed", log])
            is_followed = res.rc == 0
            if is_followed:
                continue
            
            # Mark as changed
            followed = True
            if ctx.check_mode:
                continue  # Will return changed=True below
            
            # Build follow command
            cmd = [le_path, "follow", log]
            if name:
                cmd.extend(["--name", name])
            if logtype:
                cmd.extend(["--type", logtype])
            
            res = ctx.run(cmd)
            if res.rc != 0:
                fail("failed to follow '%s': %s" % (log, res.stderr.strip()))
            
            # Verify follow succeeded
            res = ctx.run([le_path, "followed", log])
            if res.rc != 0:
                fail("failed to follow '%s': command succeeded but log not followed" % log)
        
        if followed:
            return {"changed": True, "msg": "followed %d log(s)" % len([l for l in logs if not ctx.run([le_path, "followed", l]).rc == 0])}
        else:
            return {"changed": False, "msg": "log(s) already followed"}
    
    elif state in ["absent", "unfollowed"]:
        # Unfollow logs
        removed = False
        for log in logs:
            # Check if currently followed
            res = ctx.run([le_path, "followed", log])
            is_followed = res.rc == 0
            if not is_followed:
                continue
            
            # Mark as changed
            removed = True
            if ctx.check_mode:
                continue  # Will return changed=True below
            
            # Remove the log
            res = ctx.run([le_path, "rm", log])
            if res.rc != 0:
                fail("failed to remove '%s': %s" % (log, res.stderr.strip()))
            
            # Verify removal succeeded
            res = ctx.run([le_path, "followed", log])
            if res.rc == 0:
                fail("failed to remove '%s': command succeeded but log still followed" % log)
        
        if removed:
            return {"changed": True, "msg": "removed %d log(s)" % removed}
        else:
            return {"changed": False, "msg": "log(s) already unfollowed"}
    
    fail("unsupported state: " + state)
