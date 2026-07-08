def main(ctx, params):
    state = params.get("state", "present")
    name = params["name"]
    handler_type = params.get("type")
    filter_val = params.get("filter")
    filters = params.get("filters")
    severities = params.get("severities")
    mutator = params.get("mutator")
    timeout = params.get("timeout", 10)
    handle_silenced = params.get("handle_silenced", False)
    handle_flapping = params.get("handle_flapping", False)
    command = params.get("command")
    socket = params.get("socket")
    pipe = params.get("pipe")
    handlers = params.get("handlers")

    # Validation: required fields
    if state == "absent":
        path = "/etc/sensu/conf.d/handlers/%s.json" % name
        if ctx.file_exists(path):
            if ctx.check_mode:
                return {"changed": True, "msg": "/etc/sensu/conf.d/handlers/%s.json would have been deleted" % name}
            res = ctx.run(["rm", "-f", path])
            return {"changed": True, "msg": "/etc/sensu/conf.d/handlers/%s.json deleted successfully" % name}
        else:
            return {"changed": False, "msg": "/etc/sensu/conf.d/handlers/%s.json already does not exist" % name}

    # Present: validate required options
    if state == "present":
        if handler_type == None:
            fail("type is required when state is present")
        if handler_type == "pipe" and command == None:
            fail("command is required for type pipe")
        if handler_type in ["tcp", "udp"] and socket == None:
            fail("socket is required for type tcp/udp")
        if handler_type == "transport" and pipe == None:
            fail("pipe is required for type transport")
        if handler_type == "set" and handlers == None:
            fail("handlers is required for type set")

    # Build config dict (mimic original JSON structure)
    config = {"handlers": {name: {}}}
    args_list = ["type", "filter", "filters", "severities", "mutator", "timeout",
                 "handle_silenced", "handle_flapping", "command", "socket",
                 "pipe", "handlers"]

    for arg in args_list:
        val = params.get(arg)
        if val != None:
            config["handlers"][name][arg] = val

    path = "/etc/sensu/conf.d/handlers/%s.json" % name
    current_config_str = ""
    if ctx.file_exists(path):
        current_config_str = ctx.file_read(path)

    # Helper to convert config to compact JSON-like string for comparison
    def to_simple_json(o):
        if type(o) == "dict":
            if len(o) == 0:
                return "{}"
            items = []
            for k in sorted(o.keys()):
                items.append("\"%s\":%s" % (k, to_simple_json(o[k])))
            return "{" + ",".join(items) + "}"
        elif type(o) == "list":
            if len(o) == 0:
                return "[]"
            return "[" + ",".join([to_simple_json(x) for x in o]) + "]"
        elif type(o) == "bool":
            return "true" if o else "false"
        elif type(o) == "int":
            return str(o)
        elif type(o) == "NoneType":
            return "null"
        else:
            return "\"%s\"" % str(o)

    expected_json = to_simple_json(config)
    normalized_expected = "".join(expected_json.split())
    normalized_current = "".join(current_config_str.split()) if current_config_str != "" else ""

    if normalized_current == normalized_expected:
        return {"changed": False, "msg": "Handler configuration is already up to date", "name": name, "file": path, "config": config["handlers"][name]}

    # Ensure directory exists
    dir_path = "/etc/sensu/conf.d/handlers"
    if not ctx.file_exists(dir_path):
        if not ctx.check_mode:
            res = ctx.run(["mkdir", "-p", dir_path])
            if res.rc != 0:
                fail("Failed to create directory %s" % dir_path)

    # Format JSON with indentation (4 spaces)
    def indent_json(o, indent=0):
        ind = "    " * indent
        ind1 = "    " * (indent + 1)
        if type(o) == "dict":
            if len(o) == 0:
                return "{}"
            lines = ["{"]
            keys = sorted(o.keys())
            for i, k in enumerate(keys):
                v = o[k]
                if type(v) == "dict":
                    if len(v) == 0:
                        lines.append("%s\"%s\": {}" % (ind1, k) + ("," if i < len(keys)-1 else ""))
                    else:
                        lines.append("%s\"%s\": %s" % (ind1, k, indent_json(v, indent + 1)) + ("," if i < len(keys)-1 else ""))
                elif type(v) == "list":
                    if len(v) == 0:
                        lines.append("%s\"%s\": []" % (ind1, k) + ("," if i < len(keys)-1 else ""))
                    else:
                        lines.append("%s\"%s\": %s" % (ind1, k, indent_json(v, indent + 1)) + ("," if i < len(keys)-1 else ""))
                elif type(v) == "bool":
                    lines.append("%s\"%s\": %s" % (ind1, k, "true" if v else "false") + ("," if i < len(keys)-1 else ""))
                elif type(v) == "int":
                    lines.append("%s\"%s\": %s" % (ind1, k, str(v)) + ("," if i < len(keys)-1 else ""))
                elif v == None:
                    lines.append("%s\"%s\": null" % (ind1, k) + ("," if i < len(keys)-1 else ""))
                else:
                    lines.append("%s\"%s\": \"%s\"" % (ind1, k, str(v)) + ("," if i < len(keys)-1 else ""))
            lines.append("%s}" % ind)
            return "\n".join(lines)
        elif type(o) == "list":
            if len(o) == 0:
                return "[]"
            lines = ["["]
            for i, item in enumerate(o):
                if type(item) == "dict":
                    if len(item) == 0:
                        lines.append("%s{}" % ind1 + ("," if i < len(o)-1 else ""))
                    else:
                        lines.append("%s%s" % (ind1, indent_json(item, indent + 1)) + ("," if i < len(o)-1 else ""))
                elif type(item) == "list":
                    if len(item) == 0:
                        lines.append("%s[]" % ind1 + ("," if i < len(o)-1 else ""))
                    else:
                        lines.append("%s%s" % (ind1, indent_json(item, indent + 1)) + ("," if i < len(o)-1 else ""))
                elif type(item) == "bool":
                    lines.append("%s%s" % (ind1, "true" if item else "false") + ("," if i < len(o)-1 else ""))
                elif type(item) == "int":
                    lines.append("%s%s" % (ind1, str(item)) + ("," if i < len(o)-1 else ""))
                elif item == None:
                    lines.append("%snull" % ind1 + ("," if i < len(o)-1 else ""))
                else:
                    lines.append("%s\"%s\"" % (ind1, str(item)) + ("," if i < len(o)-1 else ""))
            lines.append("%s]" % ind)
            return "\n".join(lines)
        else:
            return str(o)

    pretty_content = indent_json(config)
    changed = ctx.file_write(path, pretty_content)

    if ctx.check_mode:
        return {"changed": True, "msg": "Handler configuration would have been updated", "name": name, "file": path, "config": config["handlers"][name]}

    return {"changed": True, "msg": "Handler configuration updated", "name": name, "file": path, "config": config["handlers"][name]}
