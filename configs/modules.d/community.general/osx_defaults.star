def main(ctx, params):
    # Extract parameters
    domain = params.get("domain", "NSGlobalDomain")
    host = params.get("host")
    key = params.get("key")
    type_ = params.get("type", "string")
    array_add = params.get("array_add", False)
    value = params.get("value")
    state = params.get("state", "present")
    path = params.get("path", "/usr/bin:/usr/local/bin")

    # Validate required parameters
    if key == None:
        fail("key is required")
    if state == "present" and value == None:
        fail("value is required when state is present")

    # Find defaults executable
    search_dirs = path.split(":")
    defaults_path = None
    for d in search_dirs:
        if d == "":
            continue
        full_path = d.rstrip("/") + "/defaults"
        if ctx.file_exists(full_path):
            defaults_path = full_path
            break
    if defaults_path == None:
        fail("Unable to locate defaults executable")

    # Helper: convert value to proper type
    def convert_type(data_type, val):
        if data_type == "string":
            return str(val)
        elif data_type in ["bool", "boolean"]:
            if type(val) == "string":
                val = val.lower()
            if val == True or val == 1 or val == "true" or val == "1" or val == "yes":
                return True
            elif val == False or val == 0 or val == "false" or val == "0" or val == "no":
                return False
            fail("Invalid boolean value: " + repr(val))
        elif data_type == "date":
            fail("date type not implemented")
        elif data_type in ["int", "integer"]:
            s = str(val)
            if (s.startswith("-") and s[1:].isdigit()) or s.isdigit():
                return int(val)
            fail("Invalid integer value: " + repr(val))
        elif data_type == "float":
            val_float = float(val)
            return val_float
        elif data_type == "array":
            if type(val) != "list":
                fail("Invalid value. Expected value to be an array")
            return val
        fail("Type is not supported: " + data_type)

    # Build command base
    def base_cmd():
        cmd = [defaults_path]
        if host != None:
            if host == "currentHost":
                cmd.append("-currentHost")
            else:
                cmd.extend(["-host", host])
        return cmd

    # Read current value and type
    rc, stdout, stderr = ctx.run(base_cmd() + ["read-type", domain, key])
    current_value = None
    current_type = None

    if rc == 1:
        current_value = None
    elif rc != 0:
        fail("An error occurred while reading key type from defaults: " + stderr)
    else:
        # Extract type from output
        output = stdout.strip()
        if output.startswith("Type is "):
            current_type = output.replace("Type is ", "").strip()
        else:
            fail("Unexpected read-type output: " + stdout)

        # Read actual value
        rc, stdout, stderr = ctx.run(base_cmd() + ["read", domain, key])
        if rc != 0 and rc != 1:
            fail("An error occurred while reading key value from defaults: " + stderr)
        elif rc == 0:
            # Parse array values from defaults output
            if current_type == "array":
                lines = stdout.splitlines()
                # Skip header and footer
                if len(lines) > 2:
                    items = lines[1:-1]
                    cleaned = []
                    for item in items:
                        # Strip leading spaces and trailing comma/quote
                        item = item.strip()
                        item = item.rstrip(",").strip()
                        item = item.strip('"').replace('\\"', '"')
                        cleaned.append(item)
                    current_value = cleaned
                else:
                    current_value = []
            else:
                current_value = stdout.strip()
            # Convert to target type
            current_value = convert_type(current_type, current_value)

    # Handle 'list' state
    if state == "list":
        return {"changed": False, "msg": "Read key value", "data": {"key": key, "value": current_value}}

    # Handle 'absent' state
    if state == "absent":
        if current_value == None:
            return {"changed": False, "msg": "Key does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete key " + key}
        rc, stdout, stderr = ctx.run(base_cmd() + ["delete", domain, key])
        if rc != 0:
            fail("An error occurred while deleting key from defaults: " + stderr)
        return {"changed": True, "msg": "Deleted key " + key}

    # Handle 'present' state
    converted_value = convert_type(type_, value)

    # Check if value needs to be changed
    changed = False
    if current_value == None:
        changed = True
    elif type_ == "array":
        if array_add:
            # For array_add, check if all new values already exist
            current_set = set(current_value)
            new_items = [v for v in converted_value if v not in current_set]
            changed = len(new_items) > 0
        else:
            changed = set(current_value) != set(converted_value)
    else:
        changed = current_value != converted_value

    if not changed:
        return {"changed": False, "msg": "Value already correct"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would update key " + key}

    # Prepare value for writing
    write_value = None
    if type(converted_value) == "bool":
        write_value = "TRUE" if converted_value else "FALSE"
    elif type(converted_value) in ["int", "float"]:
        write_value = str(converted_value)
    elif type(converted_value) == "list":
        if array_add and current_value != None:
            # Only add new items
            current_set = set(current_value)
            write_value = [v for v in converted_value if v not in current_set]
        else:
            write_value = converted_value
    else:
        write_value = converted_value

    # Build arguments list
    args = ["write", domain, key]
    if type_ == "array" and array_add:
        args.append("-array-add")
    else:
        args.append("-" + type_)

    # Convert to string list for command
    if type(write_value) != "list":
        args.append(str(write_value))
    else:
        for v in write_value:
            args.append(str(v))

    rc, stdout, stderr = ctx.run(base_cmd() + args)
    if rc != 0:
        fail("An error occurred while writing value to defaults: " + stderr)

    return {"changed": True, "msg": "Updated key " + key}
