def main(ctx, params):
    name = params["name"]
    state = params.get("state")
    enabled = params.get("enabled")
    force_stop = params.get("force_stop", False)
    
    # At least one of state and enabled are required
    if state == None and enabled == None:
        fail("one of state or enabled is required")
    
    # Find service plist file
    home = ctx.facts().get("home", "")
    launchd_paths = [
        home + "/Library/LaunchAgents" if home else "",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/System/Library/LaunchAgents",
        "/System/Library/LaunchDaemons"
    ]
    
    plist_path = None
    for path in launchd_paths:
        if not path:
            continue
        if ctx.file_exists(path):
            # List directory contents using shell
            res = ctx.run(["ls", "-1", path], mutates=False)
            if res.rc == 0:
                files = res.stdout.strip().split("\n") if res.stdout.strip() else []
                service_plist = name + ".plist"
                if service_plist in files:
                    plist_path = path + "/" + service_plist
                    break
    
    if plist_path == None:
        # Try to get status to provide better error message
        res = ctx.run(["launchctl", "list"], mutates=False)
        active_services = []
        if res.rc == 0:
            for line in res.stdout.split("\n"):
                parts = line.strip().split("\t")
                if len(parts) >= 3:
                    active_services.append(parts[2])
        msg = "Unable to infer the path of %s service plist file" % name
        if res.rc != 0 or name not in active_services:
            msg += " and it was not found among active services"
        fail(msg)
    
    # Get initial service state
    res = ctx.run(["launchctl", "list"], mutates=False)
    current_state = "unloaded"
    current_pid = "-"
    for line in res.stdout.split("\n"):
        parts = line.strip().split("\t")
        if len(parts) >= 3 and parts[2].strip() == name:
            current_pid = parts[0]
            last_exit_code = parts[1]
            if last_exit_code in ['0', '-2', '-3', '-9', '-15']:
                current_state = "started" if current_pid != "-" else "stopped"
            else:
                current_state = "unknown"
            break
    
    previous_state = current_state
    previous_pid = current_pid
    
    # Process enabled and force_stop options by modifying plist
    changed = False
    if enabled != None or force_stop:
        # Read current plist
        plist_content = ctx.file_read(plist_path)
        lines = plist_content.split("\n")
        
        # Simple plist parsing (basic approach for RunAtLoad and KeepAlive)
        new_lines = []
        modified = False
        
        for line in lines:
            stripped = line.strip()
            if enabled != None and stripped.startswith("RunAtLoad"):
                key = "RunAtLoad"
                new_value = "true" if enabled else "false"
                if stripped != key + " = " + new_value and stripped != key + "=" + new_value:
                    new_lines.append(key + " = " + new_value)
                    modified = True
                else:
                    new_lines.append(line)
            elif force_stop and stripped.startswith("KeepAlive"):
                key = "KeepAlive"
                new_value = "false" if force_stop else "true"
                if stripped != key + " = " + new_value and stripped != key + "=" + new_value:
                    new_lines.append(key + " = " + new_value)
                    modified = True
                else:
                    new_lines.append(line)
            else:
                new_lines.append(line)
        
        if modified:
            new_plist_content = "\n".join(new_lines)
            if not ctx.check_mode:
                ctx.file_write(plist_path, new_plist_content)
            changed = True
    
    # Execute state action
    if state != None:
        # Get current state again after potential plist changes
        res = ctx.run(["launchctl", "list"], mutates=False)
        for line in res.stdout.split("\n"):
            parts = line.strip().split("\t")
            if len(parts) >= 3 and parts[2].strip() == name:
                current_pid = parts[0]
                last_exit_code = parts[1]
                if last_exit_code in ['0', '-2', '-3', '-9', '-15']:
                    current_state = "started" if current_pid != "-" else "stopped"
                else:
                    current_state = "unknown"
                break
        
        # Action handling
        if state == "started":
            if current_state == "started":
                return {"changed": changed, "msg": name + " already started", "status": {
                    "previous_state": previous_state,
                    "previous_pid": previous_pid,
                    "current_state": current_state,
                    "current_pid": current_pid
                }}
            
            if not ctx.check_mode:
                # Load if needed, then start
                res = ctx.run(["launchctl", "load", plist_path], mutates=True)
                if res.rc != 0 and "is already loaded" not in res.stderr:
                    fail("failed to load " + name + ": " + res.stderr)
                
                res = ctx.run(["launchctl", "start", name], mutates=True)
                if res.rc != 0:
                    fail("failed to start " + name + ": " + res.stderr)
                
                # Simulate wait by polling
                for _ in range(5):
                    res = ctx.run(["sleep", "1"], mutates=False)
                    if res.rc != 0:
                        pass  # ignore sleep failure
                
                # Verify state
                res = ctx.run(["launchctl", "list"], mutates=False)
                for line in res.stdout.split("\n"):
                    parts = line.strip().split("\t")
                    if len(parts) >= 3 and parts[2].strip() == name:
                        current_pid = parts[0]
                        current_state = "started" if current_pid != "-" else "stopped"
                        break
            
            return {"changed": True, "msg": "started " + name, "status": {
                "previous_state": previous_state,
                "previous_pid": previous_pid,
                "current_state": current_state,
                "current_pid": current_pid
            }}
        
        elif state == "stopped":
            if current_state == "stopped":
                return {"changed": changed, "msg": name + " already stopped", "status": {
                    "previous_state": previous_state,
                    "previous_pid": previous_pid,
                    "current_state": current_state,
                    "current_pid": current_pid
                }}
            
            if not ctx.check_mode:
                # Unload if loaded, then stop
                res = ctx.run(["launchctl", "unload", plist_path], mutates=True)
                if res.rc != 0 and "is not loaded" not in res.stderr:
                    fail("failed to unload " + name + ": " + res.stderr)
                
                res = ctx.run(["launchctl", "stop", name], mutates=True)
                if res.rc != 0:
                    fail("failed to stop " + name + ": " + res.stderr)
                
                # Simulate wait by polling
                for _ in range(5):
                    res = ctx.run(["sleep", "1"], mutates=False)
                    if res.rc != 0:
                        pass  # ignore sleep failure
                
                current_pid = "-"
                current_state = "stopped"
            
            return {"changed": True, "msg": "stopped " + name, "status": {
                "previous_state": previous_state,
                "previous_pid": previous_pid,
                "current_state": current_state,
                "current_pid": current_pid
            }}
        
        elif state == "reloaded":
            if not ctx.check_mode:
                # Unload then load
                res = ctx.run(["launchctl", "unload", plist_path], mutates=True)
                res2 = ctx.run(["launchctl", "load", plist_path], mutates=True)
                if res.rc != 0 and "is not loaded" not in res.stderr:
                    fail("failed to unload " + name + ": " + res.stderr)
                if res2.rc != 0:
                    fail("failed to load " + name + ": " + res2.stderr)
            
            return {"changed": True, "msg": "reloaded " + name, "status": {
                "previous_state": previous_state,
                "previous_pid": previous_pid,
                "current_state": current_state,
                "current_pid": current_pid
            }}
        
        elif state == "restarted":
            if not ctx.check_mode:
                # Stop then start ( unload + load + start )
                res = ctx.run(["launchctl", "unload", plist_path], mutates=True)
                res2 = ctx.run(["launchctl", "load", plist_path], mutates=True)
                if res.rc != 0 and "is not loaded" not in res.stderr:
                    fail("failed to unload " + name + ": " + res.stderr)
                if res2.rc != 0:
                    fail("failed to load " + name + ": " + res2.stderr)
                
                res = ctx.run(["launchctl", "start", name], mutates=True)
                if res.rc != 0:
                    fail("failed to start " + name + ": " + res.stderr)
            
            return {"changed": True, "msg": "restarted " + name, "status": {
                "previous_state": previous_state,
                "previous_pid": previous_pid,
                "current_state": "started",
                "current_pid": "-"
            }}
        
        elif state == "unloaded":
            if current_state == "unloaded":
                return {"changed": changed, "msg": name + " already unloaded", "status": {
                    "previous_state": previous_state,
                    "previous_pid": previous_pid,
                    "current_state": current_state,
                    "current_pid": current_pid
                }}
            
            if not ctx.check_mode:
                res = ctx.run(["launchctl", "unload", plist_path], mutates=True)
                if res.rc != 0 and "is not loaded" not in res.stderr:
                    fail("failed to unload " + name + ": " + res.stderr)
            
            return {"changed": True, "msg": "unloaded " + name, "status": {
                "previous_state": previous_state,
                "previous_pid": previous_pid,
                "current_state": "unloaded",
                "current_pid": "-"
            }}
    
    return {"changed": changed, "msg": "service configuration updated", "status": {
        "previous_state": previous_state,
        "previous_pid": previous_pid,
        "current_state": current_state,
        "current_pid": current_pid
    }}
