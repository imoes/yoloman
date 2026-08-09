def main(ctx, params):
    key = params["key"]
    state = params["state"]
    direct = params.get("direct", False)
    config_source = params.get("config_source")
    value_type = params.get("value_type")
    value = params.get("value")

    # Validation rules from original module
    if direct and config_source == None:
        fail('"direct" requires "config_source" to be specified')
    if not direct and config_source != None:
        fail('"config_source" without "direct" is invalid')
    if state == "present":
        if value == None:
            fail('"value" is required when state=present')
        if value_type == None:
            fail('"value_type" is required when state=present')

    # Build gconftool-2 command base
    cmd = ["gconftool-2", "--get", key]
    if direct:
        cmd = ["gconftool-2", "--direct", "--config-source", config_source, "--get", key]

    # Probe current value
    res = ctx.run(cmd)
    current_value = res.stdout.rstrip() if res.rc == 0 else None
    # In original, empty string maps to null for non-existent key; preserve that
    current_value = None if current_value == "" else current_value

    if state == "absent":
        if current_value == None:
            return {"changed": False, "msg": "key already absent", "key": key, "value_type": value_type, "value": None, "previous_value": current_value}
        # Remove key
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove key", "key": key, "value_type": value_type, "value": None, "previous_value": current_value}
        if direct:
            cmd = ["gconftool-2", "--direct", "--config-source", config_source, "--unset", key]
        else:
            cmd = ["gconftool-2", "--unset", key]
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("failed to unset key: " + res.stderr)
        return {"changed": True, "msg": "key removed", "key": key, "value_type": value_type, "value": None, "previous_value": current_value}

    if state == "present":
        # Determine if change is needed
        if current_value != None and current_value == value:
            return {"changed": False, "msg": "value already set", "key": key, "value_type": value_type, "value": value, "previous_value": current_value}

        # Build set command
        if direct:
            base_cmd = ["gconftool-2", "--direct", "--config-source", config_source, "--type", value_type, "--set", key]
        else:
            base_cmd = ["gconftool-2", "--type", value_type, "--set", key]

        if value_type == "bool":
            # Normalize value to lowercase string for gconftool-2
            if value.lower() in ("true", "1", "yes", "on"):
                arg_value = "true"
            elif value.lower() in ("false", "0", "no", "off"):
                arg_value = "false"
            else:
                fail("invalid boolean value: " + value)
        else:
            arg_value = value

        set_cmd = base_cmd + [arg_value]

        if ctx.check_mode:
            return {"changed": True, "msg": "would update value", "key": key, "value_type": value_type, "value": value, "previous_value": current_value}

        res = ctx.run(set_cmd, mutates=True)
        if res.rc != 0:
            fail("failed to set key: " + res.stderr)

        # Confirm new value
        res = ctx.run(cmd)
        new_value = res.stdout.rstrip() if res.rc == 0 else None
        new_value = None if new_value == "" else new_value

        return {"changed": True, "msg": "value updated", "key": key, "value_type": value_type, "value": new_value, "previous_value": current_value}

    fail("unsupported state: " + state)
