def main(ctx, params):
    name = params["name"]
    path = params.get("path", "/etc/sensu/conf.d/checks.json")
    state = params.get("state", "present")
    backup = params.get("backup", False)
    command = params.get("command")
    metric = params.get("metric", False)
    subdue_begin = params.get("subdue_begin")
    subdue_end = params.get("subdue_end")
    custom = params.get("custom")
    simple_opts = [
        "command",
        "handlers",
        "subscribers",
        "interval",
        "timeout",
        "ttl",
        "handle",
        "dependencies",
        "standalone",
        "publish",
        "occurrences",
        "refresh",
        "aggregate",
        "low_flap_threshold",
        "high_flap_threshold",
        "source",
    ]

    # Validation
    if state == "absent" and command != None:
        pass
    if state != "absent" and command == None:
        fail("missing required arguments: command")
    if subdue_begin != None and subdue_end == None:
        fail("subdue_begin requires subdue_end")
    if subdue_end != None and subdue_begin == None:
        fail("subdue_end requires subdue_begin")
    if custom != None:
        overwrited_fields = []
        for k in custom.keys():
            if k in (simple_opts + ["type", "subdue", "subdue_begin", "subdue_end"]):
                overwrited_fields.append(k)
        if len(overwrited_fields) > 0:
            fail("You can't overwriting standard module parameters via 'custom'. You are trying overwrite: " + str(overwrited_fields))

    # JSON parsing is not supported in pure Starlark — fail gracefully
    fail("This module cannot be translated to pure Starlark because it requires JSON parsing. Use the original Ansible module.")
