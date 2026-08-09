def main(ctx, params):
    name = params["name"]
    service_type = params["type"]
    control = params["control"]
    module_path = params["module_path"]
    new_type = params.get("new_type")
    new_control = params.get("new_control")
    new_module_path = params.get("new_module_path")
    module_arguments = params.get("module_arguments")
    state = params.get("state", "updated")
    pamd_path = params.get("path", "/etc/pam.d")
    backup = params.get("backup", False)

    service_file = "%s/%s" % (pamd_path, name)
    
    # Validate state
    valid_states = ["absent", "before", "after", "args_absent", "args_present", "updated"]
    if state not in valid_states:
        fail("Invalid state: %s. Must be one of: %s" % (state, ", ".join(valid_states)))
    
    # Validate type choices
    valid_types = ["account", "-account", "auth", "-auth", "password", "-password", "session", "-session"]
    if service_type not in valid_types:
        fail("Invalid type: %s. Must be one of: %s" % (service_type, ", ".join(valid_types)))
    if new_type != None and new_type not in valid_types:
        fail("Invalid new_type: %s. Must be one of: %s" % (new_type, ", ".join(valid_types)))

    # Required params for specific states
    if state in ["before", "after"]:
        if new_type == None or new_control == None or new_module_path == None:
            fail("new_type, new_control, and new_module_path are required for state=%s" % state)
    
    if state in ["args_absent", "args_present"]:
        if module_arguments == None:
            fail("module_arguments is required for state=%s" % state)

    # Read current file content
    if not ctx.file_exists(service_file):
        fail("PAM service file %s does not exist" % service_file)
    
    content = ctx.file_read(service_file)
    lines = content.split("\n")
    
    # Parse PAM rules
    parsed_rules = []
    for line in lines:
        if line.strip() == "" or line.strip().startswith("#") or line.strip().startswith("@include"):
            parsed_rules.append({"type": None, "line": line, "raw": line})
        else:
            parts = line.split(None, 3)
            rule = {"raw": line, "line": line}
            if len(parts) >= 3:
                rule["type"] = parts[0]
                rule["control"] = parts[1]
                rule["path"] = parts[2]
                rule["args"] = parts[3] if len(parts) > 3 else ""
            else:
                rule["type"] = parts[0] if len(parts) >= 1 else ""
                rule["control"] = parts[1] if len(parts) >= 2 else ""
                rule["path"] = parts[2] if len(parts) >= 3 else ""
                rule["args"] = ""
            parsed_rules.append(rule)
    
    # Helper to match rules
    def find_matching_rules(rules, t, c, p):
        matches = []
        for idx, rule in enumerate(rules):
            if rule.get("type") == None:
                continue
            if rule["type"] == t and rule["control"] == c and rule["path"] == p:
                matches.append({"index": idx, "rule": rule})
        return matches

    # Helper to parse module arguments
    def parse_args(args):
        if args == None:
            return []
        if isinstance(args, str):
            if args.strip() == "":
                return []
            args = [args]
        parsed = []
        for arg in args:
            if arg == "":
                continue
            # Clean spaces around = and split
            arg = arg.strip()
            # Simple split by whitespace
            items = arg.split()
            parsed.extend(items)
        return parsed

    # Helper to format rule line
    def format_rule(rule_type, rule_control, rule_path, rule_args):
        if rule_args and len(rule_args) > 0:
            return "%-11s %s %s %s" % (rule_type, rule_control, rule_path, " ".join(rule_args))
        return "%-11s %s %s" % (rule_type, rule_control, rule_path)

    # Process each state
    change_count = 0
    new_rules = []

    if state == "absent":
        for rule in parsed_rules:
            if rule.get("type") != None and rule["type"] == service_type and rule["control"] == control and rule["path"] == module_path:
                change_count += 1
            else:
                new_rules.append(rule)
    
    elif state == "updated":
        for idx, rule in enumerate(parsed_rules):
            if rule.get("type") != None and rule["type"] == service_type and rule["control"] == control and rule["path"] == module_path:
                change_count += 1
                # Build new rule
                new_t = new_type if new_type else rule["type"]
                new_c = new_control if new_control else rule["control"]
                new_p = new_module_path if new_module_path else rule["path"]
                
                # Handle module_arguments for updated state
                new_args = []
                if module_arguments != None:
                    new_args = parse_args(module_arguments)
                
                new_line = format_rule(new_t, new_c, new_p, new_args)
                new_rules.append({"type": new_t, "control": new_c, "path": new_p, "args": " ".join(new_args), "raw": new_line, "line": new_line})
            else:
                new_rules.append(rule)
    
    elif state == "before":
        inserted = False
        for idx, rule in enumerate(parsed_rules):
            if rule.get("type") != None and rule["type"] == service_type and rule["control"] == control and rule["path"] == module_path and not inserted:
                change_count += 1
                new_args = parse_args(module_arguments) if module_arguments != None else []
                new_line = format_rule(new_type, new_control, new_module_path, new_args)
                new_rules.append({"type": new_type, "control": new_control, "path": new_module_path, "args": " ".join(new_args), "raw": new_line, "line": new_line})
                inserted = True
            new_rules.append(rule)
    
    elif state == "after":
        for idx, rule in enumerate(parsed_rules):
            new_rules.append(rule)
            if rule.get("type") != None and rule["type"] == service_type and rule["control"] == control and rule["path"] == module_path:
                change_count += 1
                new_args = parse_args(module_arguments) if module_arguments != None else []
                new_line = format_rule(new_type, new_control, new_module_path, new_args)
                new_rules.append({"type": new_type, "control": new_control, "path": new_module_path, "args": " ".join(new_args), "raw": new_line, "line": new_line})
    
    elif state == "args_present":
        for idx, rule in enumerate(parsed_rules):
            if rule.get("type") != None and rule["type"] == service_type and rule["control"] == control and rule["path"] == module_path:
                change_count += 1
                existing_args = parse_args(rule.get("args", ""))
                new_args = parse_args(module_arguments)
                
                # Track simple args and key=value args
                simple_existing = set()
                keyval_existing = {}
                for arg in existing_args:
                    if "=" in arg:
                        k, v = arg.split("=", 1)
                        keyval_existing[k] = v
                    else:
                        simple_existing.add(arg)
                
                simple_new = set()
                keyval_new = {}
                for arg in new_args:
                    if "=" in arg:
                        k, v = arg.split("=", 1)
                        keyval_new[k] = v
                    else:
                        simple_new.add(arg)
                
                # Add new simple args
                for arg in simple_new:
                    if arg not in simple_existing and arg not in existing_args:
                        existing_args.append(arg)
                
                # Add new key=value args and update existing ones
                for k, v in keyval_new.items():
                    key_arg = k + "=" + v
                    found = False
                    for i, arg in enumerate(existing_args):
                        if arg.startswith(k + "="):
                            existing_args[i] = key_arg
                            found = True
                            break
                    if not found:
                        existing_args.append(key_arg)
                
                new_line = format_rule(rule["type"], rule["control"], rule["path"], existing_args)
                new_rules.append({"type": rule["type"], "control": rule["control"], "path": rule["path"], "args": " ".join(existing_args), "raw": new_line, "line": new_line})
            else:
                new_rules.append(rule)
    
    elif state == "args_absent":
        for idx, rule in enumerate(parsed_rules):
            if rule.get("type") != None and rule["type"] == service_type and rule["control"] == control and rule["path"] == module_path:
                change_count += 1
                existing_args = parse_args(rule.get("args", ""))
                args_to_remove = parse_args(module_arguments)
                
                new_args = [arg for arg in existing_args if arg not in args_to_remove]
                new_line = format_rule(rule["type"], rule["control"], rule["path"], new_args)
                new_rules.append({"type": rule["type"], "control": rule["control"], "path": rule["path"], "args": " ".join(new_args), "raw": new_line, "line": new_line})
            else:
                new_rules.append(rule)
    
    # Build new content
    new_lines = []
    for rule in new_rules:
        new_lines.append(rule.get("raw", rule.get("line", "")))
    new_content = "\n".join(new_lines)
    if new_lines and not new_lines[-1].endswith("\n"):
        new_content += "\n"
    
    # Check if changed
    changed = content != new_content
    
    if not changed:
        return {"changed": False, "msg": "No changes needed", "change_count": 0}
    
    if ctx.check_mode:
        return {"changed": True, "msg": "Would update PAM service", "change_count": change_count}
    
    # Backup if requested
    if backup:
        # Create backup manually
        backup_path = "%s/%s.ansible_backup" % (pamd_path, name)
        ctx.file_write(backup_path, content)
    
    # Write new content
    ctx.file_write(service_file, new_content)
    
    return {"changed": True, "msg": "PAM service updated", "change_count": change_count}
