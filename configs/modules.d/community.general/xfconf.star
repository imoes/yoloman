def main(ctx, params):
    channel = params["channel"]
    property_name = params["property"]
    state = params.get("state", "present")
    value = params.get("value", [])
    value_type = params.get("value_type", [])
    force_array = params.get("force_array", False)

    # Validate state
    if state not in ("present", "absent"):
        fail("unsupported state: " + state + ". Must be 'present' or 'absent'")

    # For state=present, require value and value_type
    if state == "present":
        if value == None or len(value) == 0:
            fail("value is required when state is present")
        if value_type == None or len(value_type) == 0:
            fail("value_type is required when state is present")

    # Normalize value and value_type lists
    values = []
    types = []
    if state == "present":
        values = [str(v) for v in value]
        types = [str(t) for t in value_type]
        values_len = len(values)
        types_len = len(types)

        if types_len == 1:
            types = types * values_len
        elif types_len != values_len:
            fail("Number of elements in value and value_type must be the same")

    # Get current value
    get_cmd = ["xfconf-query", "--channel", channel, "--property", property_name]
    res = ctx.run(get_cmd)
    if res.rc != 0 and "does not exist" not in res.stderr.lower():
        fail("failed to get property: " + res.stderr)

    previous_value = None
    if res.rc == 0 and res.stdout.strip():
        out = res.stdout.strip()
        if "Value is an array with" in out:
            lines = out.splitlines()
            # Skip first two lines (header lines)
            values_list = [l.strip() for l in lines[2:] if l.strip()]
            previous_value = values_list if values_list else []
        else:
            previous_value = out

    # Check current state
    if state == "absent":
        if previous_value == None:
            return {"changed": False, "msg": "Property already absent", "channel": channel, "property": property_name, "previous_value": None, "value": None}
        # Perform reset
        reset_cmd = ["xfconf-query", "--channel", channel, "--property", property_name, "--reset"]
        if ctx.check_mode:
            return {"changed": True, "msg": "would reset property", "channel": channel, "property": property_name, "previous_value": previous_value, "value": None}
        res = ctx.run(reset_cmd, mutates=True)
        if res.rc != 0:
            fail("failed to reset property: " + res.stderr)
        return {"changed": True, "msg": "property reset", "channel": channel, "property": property_name, "previous_value": previous_value, "value": None}

    # state == "present"
    is_array = force_array or (previous_value != None and isinstance(previous_value, list)) or len(values) > 1

    # Build set command
    set_cmd = ["xfconf-query", "--channel", channel, "--property", property_name, "--create"]
    if is_array:
        set_cmd.extend(["--force-array", "--type"])
        # For arrays, we need to specify array element types
        if types[0] == "string":
            set_cmd.append("string")
        elif types[0] == "int":
            set_cmd.append("int")
        elif types[0] == "double":
            set_cmd.append("double")
        elif types[0] == "bool":
            set_cmd.append("bool")
        elif types[0] == "uint":
            set_cmd.append("uint")
        elif types[0] == "uchar":
            set_cmd.append("uchar")
        elif types[0] == "char":
            set_cmd.append("char")
        elif types[0] == "uint64":
            set_cmd.append("uint64")
        elif types[0] == "int64":
            set_cmd.append("int64")
        elif types[0] == "float":
            set_cmd.append("float")
        set_cmd.append("--set")
        set_cmd.extend(values)
    else:
        set_cmd.extend(["--type", types[0], "--set", values[0]])

    if ctx.check_mode:
        return {"changed": True, "msg": "would update property", "channel": channel, "property": property_name, "previous_value": previous_value, "value": values if is_array else values[0]}

    res = ctx.run(set_cmd, mutates=True)
    if res.rc != 0:
        fail("failed to set property: " + res.stderr)

    return {"changed": True, "msg": "property updated", "channel": channel, "property": property_name, "previous_value": previous_value, "value": values if is_array else values[0]}
