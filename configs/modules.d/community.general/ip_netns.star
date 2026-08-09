def main(ctx, params):
    name = params.get("name")
    state = params.get("state", "present")

    if name == None:
        fail("name is required")

    # Probe current state: list existing namespaces
    res = ctx.run(["ip", "netns", "list"], mutates=False)
    if res.rc != 0:
        fail("failed to list namespaces: " + res.stderr)

    # Check if desired namespace exists in the list
    namespaces = res.stdout.strip().split("\n") if res.stdout.strip() else []
    existing_names = []
    for line in namespaces:
        # ip netns list format: "namespace_name pid 1234" or just "namespace_name"
        parts = line.strip().split()
        if parts:
            existing_names.append(parts[0])
    exists = name in existing_names

    # check_mode handling
    if ctx.check_mode:
        if (state == "present" and not exists) or (state == "absent" and exists):
            return {"changed": True, "msg": "would " + ("create" if state == "present" else "delete") + " namespace " + name}
        return {"changed": False, "msg": name + " already " + ("exists" if state == "present" else "does not exist")}

    # Real execution
    if state == "present":
        if exists:
            return {"changed": False, "msg": "namespace " + name + " already exists"}
        res = ctx.run(["ip", "netns", "add", name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create namespace " + name}
        if res.rc != 0:
            fail("failed to create namespace " + name + ": " + res.stderr)
        return {"changed": True, "msg": "created namespace " + name}

    elif state == "absent":
        if not exists:
            return {"changed": False, "msg": "namespace " + name + " does not exist"}
        res = ctx.run(["ip", "netns", "del", name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete namespace " + name}
        if res.rc != 0:
            fail("failed to delete namespace " + name + ": " + res.stderr)
        return {"changed": True, "msg": "deleted namespace " + name}

    fail("unsupported state: " + state)
