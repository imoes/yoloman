def main(ctx, params):
    state = params.get("state", "present")
    path = "/etc/sensu/conf.d/client.json"

    # Handle absent state
    if state == "absent":
        if ctx.file_exists(path):
            if ctx.check_mode:
                return {"changed": True, "msg": path + " would have been deleted"}
            res = ctx.run(["rm", "-f", path], mutates=True)
            if res.rc != 0:
                fail("Failed to delete " + path + ": " + res.stderr)
            return {"changed": True, "msg": path + " deleted successfully"}
        else:
            return {"changed": False, "msg": path + " already does not exist"}

    # For present state, require subscriptions
    if params.get("subscriptions") == None:
        fail("subscriptions is required when state is present")

    # Build client configuration
    config = {"client": {}}
    args = [
        "name", "address", "subscriptions", "safe_mode", "redact",
        "socket", "keepalives", "keepalive", "registration", "deregister",
        "deregistration", "ec2", "chef", "puppet", "servicenow"
    ]

    for arg in args:
        if arg in params and params[arg] != None:
            config["client"][arg] = params[arg]

    # Serialize config with indent=4 to match Ansible behavior
    def indent_json(obj, indent=0):
        spaces = " " * indent
        next_spaces = " " * (indent + 4)
        if type(obj) == "NoneType":
            return "null"
        elif type(obj) == "bool":
            return "true" if obj else "false"
        elif type(obj) == "int":
            return str(obj)
        elif type(obj) == "float":
            return str(obj)
        elif type(obj) == "string":
            escaped = obj.replace("\\", "\\\\").replace('"', '\\"')
            return '"' + escaped + '"'
        elif type(obj) == "list":
            if len(obj) == 0:
                return "[]"
            items = []
            for item in obj:
                items.append(next_spaces + indent_json(item, indent + 4))
            return "[\n" + ",\n".join(items) + "\n" + spaces + "]"
        elif type(obj) == "dict":
            if len(obj) == 0:
                return "{}"
            pairs = []
            for k in sorted(obj.keys()):
                pairs.append(next_spaces + '"' + k + '": ' + indent_json(obj[k], indent + 4))
            return "{\n" + ",\n".join(pairs) + "\n" + spaces + "}"
        else:
            fail("Unsupported type in JSON serialization: " + str(type(obj)))

    desired_json = indent_json(config)

    # Load current config and compare
    current = None
    if ctx.file_exists(path):
        current = ctx.file_read(path)

    if current != None and current.strip() == desired_json.strip():
        return {"changed": False, "msg": "Client configuration is already up to date", "data": {"config": config["client"], "file": path}}

    # Ensure directory exists before writing
    dir_path = path.rsplit("/", 1)[0]
    if not ctx.check_mode and not ctx.file_exists(dir_path):
        res = ctx.run(["mkdir", "-p", dir_path], mutates=True)
        if res.rc != 0:
            fail("Unable to create directory " + dir_path)

    if ctx.check_mode:
        return {"changed": True, "msg": "Client configuration would have been updated", "data": {"config": config["client"], "file": path}}

    # Write config file
    changed = ctx.file_write(path, desired_json)
    return {"changed": True, "msg": "Client configuration updated", "data": {"config": config["client"], "file": path}}
