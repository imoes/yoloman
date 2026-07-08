def main(ctx, params):
    # Check mode
    check_mode = ctx.check_mode
    
    # Get required params
    state = params.get("state")
    default = params.get("default")
    rule = params.get("rule")
    logging = params.get("logging")
    
    # Validate that at least one command is provided
    if not state and not default and not rule and not logging:
        fail("One of state, default, rule, or logging is required")
    
    # Get ufw binary path
    res = ctx.run(["which", "ufw"])
    if res.rc != 0:
        fail("ufw command not found")
    
    ufw_bin = res.stdout.strip()
    
    # Execute based on command
    changed = False
    commands_executed = []
    
    # Handle state command
    if state:
        state_cmd = None
        if state == "enabled":
            state_cmd = "enable"
        elif state == "disabled":
            state_cmd = "disable"
        elif state == "reloaded":
            state_cmd = "reload"
        elif state == "reset":
            state_cmd = "reset"
        
        # Get current status
        pre_status = ctx.run([ufw_bin, "status", "verbose"])
        
        if state in ["reloaded", "reset"]:
            changed = True
        elif state in ["enabled", "disabled"]:
            # Check current state
            status_output = pre_status.stdout
            # Look for " active" in status (state would show as active/inactive)
            is_enabled = status_output.find(" active") != -1
            if (state == "disabled" and is_enabled) or (state == "enabled" and not is_enabled):
                changed = True
        
        if not check_mode:
            cmd = [ufw_bin]
            if state in ["enabled", "disabled", "reloaded", "reset"]:
                if state == "reset" or state == "disabled":
                    cmd.extend(["-f", state_cmd])
                else:
                    cmd.append(state_cmd)
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("Failed to set state " + state + ": " + res.stderr)
        commands_executed.append(" ".join([ufw_bin] + (["-f", state_cmd] if state in ["reset", "disabled"] else [state_cmd])))
    
    # Handle logging command
    if logging and not check_mode:
        cmd = [ufw_bin, "logging", logging]
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("Failed to set logging to " + logging + ": " + res.stderr)
        commands_executed.append(" ".join(cmd))
    
    # Handle default command
    if default:
        direction = params.get("direction")
        if direction and direction not in ["outgoing", "incoming", "routed", None]:
            fail('For default, direction must be one of "outgoing", "incoming" and "routed", or direction must not be specified.')
        
        if not check_mode:
            cmd = [ufw_bin, "default", default]
            if direction:
                cmd.append(direction)
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("Failed to set default to " + default + ": " + res.stderr)
            commands_executed.append(" ".join(cmd))
        else:
            changed = True  # Would change
    
    # Handle rule command
    if rule:
        if params.get("direction") and params.get("direction") not in ["in", "out", None]:
            fail('For rules, direction must be one of "in" and "out", or direction must not be specified.')
        
        # Build ufw rule command
        cmd = [ufw_bin]
        if params.get("route"):
            cmd.append("route")
        if params.get("delete"):
            cmd.append("delete")
        elif params.get("insert") != None and not params.get("delete"):
            insert_val = params.get("insert")
            insert_relative = params.get("insert_relative_to", "zero")
            # Simple implementation - in check_mode just assume it would work
            if insert_relative == "zero":
                cmd.append("insert %d" % insert_val)
            else:
                cmd.append("insert " + str(insert_val))
        
        cmd.append(rule)
        
        direction = params.get("direction")
        if direction:
            cmd.append(direction)
        
        interface = params.get("interface")
        if interface:
            if direction == "out":
                cmd.extend(["out", "on", interface])
            else:
                cmd.extend(["on", interface])
        
        interface_in = params.get("interface_in")
        interface_out = params.get("interface_out")
        
        # Only route rules can combine interface_in and interface_out
        if interface_in and interface_out and not params.get("route"):
            fail("Only route rules can combine interface_in and interface_out")
        
        if interface_in and interface_out:
            cmd.extend(["in", "on", interface_in, "out", "on", interface_out])
        elif interface_in:
            cmd.extend(["in", "on", interface_in])
        elif interface_out:
            cmd.extend(["out", "on", interface_out])
        
        if params.get("log"):
            cmd.append("log")
        
        # Add from_ip
        from_ip = params.get("from_ip", "any")
        if from_ip:
            cmd.append("from")
            cmd.append(from_ip)
        
        from_port = params.get("from_port")
        if from_port:
            cmd.append("port")
            cmd.append(from_port)
        
        # Add to_ip
        to_ip = params.get("to_ip", "any")
        if to_ip:
            cmd.append("to")
            cmd.append(to_ip)
        
        to_port = params.get("to_port")
        if to_port:
            cmd.append("port")
            cmd.append(to_port)
        
        proto = params.get("proto")
        if proto:
            cmd.append("proto")
            cmd.append(proto)
        
        name = params.get("name")
        if name:
            cmd.append("app")
            cmd.append("'%s'" % name)
        
        # Add comment if provided (UFW >= 0.35)
        comment = params.get("comment")
        if comment:
            cmd.append("comment")
            cmd.append("'%s'" % comment)
        
        if not check_mode:
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("Failed to add rule: " + res.stderr)
        
        commands_executed.append(" ".join(cmd))
    
    # Return result
    msg = "UFW configuration updated"
    if check_mode:
        if changed:
            msg = "would update UFW configuration"
        else:
            msg = "UFW configuration unchanged"
    
    return {"changed": changed, "msg": msg, "commands": commands_executed}
