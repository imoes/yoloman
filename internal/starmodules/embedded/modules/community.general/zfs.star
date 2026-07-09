def main(ctx, params):
    name = params["name"]
    state = params["state"]
    origin = params.get("origin")
    extra_props = params.get("extra_zfs_properties", {})

    # Validate: origin not allowed for snapshots
    if origin != None and "@" in name:
        fail("cannot specify origin when operating on a snapshot")

    # Normalize boolean properties (on/off)
    props = {}
    for k, v in extra_props.items():
        t = type(v)
        if t == "bool":
            props[k] = "on" if v else "off"
        else:
            props[k] = v

    # Helper: check if dataset exists
    def _exists():
        res = ctx.run(["zfs", "list", "-t", "all", name])
        return res.rc == 0

    # Helper: get current properties
    def _get_current_properties():
        cmd = ["zfs", "get", "-H", "-p", "-o", "property,value,source", "all", name]
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("failed to get properties for " + name + ": " + res.stderr)
        props_map = {}
        for line in res.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) >= 3:
                prop, value, source = parts[0], parts[1], parts[2]
                if source in ("local", "received", "-"):
                    props_map[prop] = value
        return props_map

    # Helper: set single property
    def _set_property(prop, value):
        cmd = ["zfs", "set", prop + "=" + str(value), name]
        ctx.run(cmd, mutates=True)

    # Helper: set properties if changed, return diff
    def _set_properties_if_changed():
        before = {}
        after = {}
        current = _get_current_properties()
        for prop, value in props.items():
            cv = current.get(prop, None)
            if cv != value:
                _set_property(prop, value)
                before[prop] = cv
                after[prop] = value
        return {"before": {"extra_zfs_properties": before}, "after": {"extra_zfs_properties": after}}

    # Determine existence
    exists = _exists()
    changed = False

    if state == "present":
        if exists:
            diff = _set_properties_if_changed()
            if diff["after"]["extra_zfs_properties"] != {}:
                changed = True
        else:
            # Create
            cmd = ["zfs"]
            if "@" in name:
                cmd.append("snapshot")
            elif origin != None:
                cmd.extend(["clone", origin])
            else:
                cmd.append("create")
            cmd.append("-p")

            # Build property flags
            for prop, value in props.items():
                if prop == "volsize":
                    cmd.extend(["-V", value])
                elif prop == "volblocksize":
                    cmd.extend(["-b", value])
                else:
                    cmd.extend(["-o", prop + "=" + value])

            cmd.append(name)
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("failed to create " + name + ": " + res.stderr)
            changed = True

    elif state == "absent":
        if exists:
            res = ctx.run(["zfs", "destroy", "-R", name], mutates=True)
            if res.rc != 0:
                fail("failed to destroy " + name + ": " + res.stderr)
            changed = True
        # else: already absent, no change

    # Build result
    result = {"name": name, "state": state}
    if state == "present":
        if exists:
            result["diff"] = {"before": {"state": "present"}, "after": {"state": "present"}}
            result["diff"]["before"]["extra_zfs_properties"] = {}
            result["diff"]["after"]["extra_zfs_properties"] = props
        else:
            result["diff"] = {"before": {"state": "absent"}, "after": {"state": "present"}}
    elif state == "absent":
        if exists:
            result["diff"] = {"before": {"state": "present"}, "after": {"state": "absent"}}
        else:
            result["diff"] = {}

    result["diff"]["before_header"] = name
    result["diff"]["after_header"] = name
    result["changed"] = changed
    if changed:
        result["msg"] = "%s %s" % (name, "removed" if state == "absent" else "created/updated")
    else:
        result["msg"] = "%s already %s" % (name, state)

    return result
