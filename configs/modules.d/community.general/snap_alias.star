def main(ctx, params):
    alias_list = params.get("alias", [])
    name = params.get("name")
    state = params.get("state", "present")

    if state == "present":
        if name == None or (not alias_list):
            fail("name and alias are required when state is present")
    elif state == "absent":
        if name == None:
            fail("name is required when state is absent")

    # Get current aliases: run 'snap alias' and parse output
    res = ctx.run(["snap", "alias"], mutates=False)
    if res.rc != 0:
        fail("failed to list snap aliases: " + res.stderr)

    # Parse the output: skip header line, parse each line for snap and alias
    lines = res.stdout.strip().split("\n")
    current_aliases = {}  # snap -> list of aliases
    if len(lines) > 1:
        for line in lines[1:]:
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) >= 2:
                snap = parts[0]
                alias = parts[1]
                if snap not in current_aliases:
                    current_aliases[snap] = []
                current_aliases[snap].append(alias)

    # Determine current state for check_mode prediction
    changed = False

    if state == "present":
        if name == None:
            changed = bool(alias_list)
        else:
            snap_aliases = current_aliases.get(name, [])
            needed = set(alias_list)
            current_set = set(snap_aliases)
            if not current_set.issuperset(needed):
                changed = True
    elif state == "absent":
        if not alias_list:
            if name != None and name in current_aliases and current_aliases[name]:
                changed = True
        else:
            if name != None and name in current_aliases:
                current_set = set(current_aliases[name])
                needed_remove = set(alias_list)
                if current_set.intersection(needed_remove):
                    changed = True

    if ctx.check_mode:
        if changed:
            return {"changed": True, "msg": "would update snap aliases", "data": {"snap_aliases": current_aliases}}
        else:
            return {"changed": False, "msg": "snap aliases already correct", "data": {"snap_aliases": current_aliases}}

    # Perform changes
    changed_flag = False

    if state == "present":
        for alias in alias_list:
            snap_list = current_aliases.get(name, [])
            if alias not in snap_list:
                res = ctx.run(["snap", "alias", name, alias], mutates=True)
                if res.rc != 0:
                    fail("failed to create alias " + alias + " for snap " + name + ": " + res.stderr)
                changed_flag = True
                if name not in current_aliases:
                    current_aliases[name] = []
                current_aliases[name].append(alias)
    elif state == "absent":
        if not alias_list:
            if name in current_aliases:
                for alias in current_aliases[name]:
                    res = ctx.run(["snap", "unalias", alias], mutates=True)
                    if res.rc != 0 and ("is not an alias" not in res.stderr):
                        fail("failed to remove alias " + alias + ": " + res.stderr)
                    changed_flag = True
                current_aliases[name] = []
        else:
            for alias in alias_list:
                if name in current_aliases and alias in current_aliases[name]:
                    res = ctx.run(["snap", "unalias", alias], mutates=True)
                    if res.rc != 0 and ("is not an alias" not in res.stderr):
                        fail("failed to remove alias " + alias + ": " + res.stderr)
                    changed_flag = True
                    new_list = []
                    for a in current_aliases[name]:
                        if a != alias:
                            new_list.append(a)
                    current_aliases[name] = new_list
                    if not current_aliases[name]:
                        # Cannot use 'del'; set to empty dict entry instead
                        current_aliases[name] = []

    return {
        "changed": changed_flag,
        "msg": "snap aliases updated" if changed_flag else "snap aliases already correct",
        "data": {"snap_aliases": current_aliases}
    }
