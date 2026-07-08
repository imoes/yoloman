def main(ctx, params):
    name = params["name"]
    lunid = params["lunid"]
    state = params.get("state", "present")
    sp_address = params["sp_address"]
    sp_user = params.get("sp_user", "sysadmin")
    sp_password = params.get("sp_password", "sysadmin")

    # check_mode: simulate without executing
    if ctx.check_mode:
        return {"changed": True, "msg": "would " + ("add" if state == "present" else "remove") + " lun " + str(lunid) + " to storage group " + name}

    # Verify storage group exists
    res = ctx.run(["scli", "-u", sp_user, "-p", sp_password, "-d", sp_address, "-q", "show storage_group " + name])
    if res.rc != 0:
        fail("failed to query storage group " + name + ": " + res.stderr)
    if "not found" in res.stdout.lower():
        fail("storage group " + name + " not found")

    # List ALUs in the storage group
    res = ctx.run(["scli", "-u", sp_user, "-p", sp_password, "-d", sp_address, "-q", "show storage_group " + name + " -i"])
    if res.rc != 0:
        fail("failed to list storage group members: " + res.stderr)

    # Parse output to check if lunid is already attached
    lines = res.stdout.splitlines()
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("ALU ID:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val_str = parts[1].strip()
                # Use int() safely; non-numeric leads to fail()
                if val_str.isdigit():
                    if int(val_str) == lunid:
                        found = True
                        break

    if state == "present":
        if found:
            return {"changed": False, "msg": "lun " + str(lunid) + " already present in storage group " + name}
        res = ctx.run(["scli", "-u", sp_user, "-p", sp_password, "-d", sp_address, "-q", "attach alu " + str(lunid) + " to storage_group " + name], mutates=True)
        if res.rc != 0:
            if "already attached" in res.stderr.lower():
                return {"changed": False, "msg": "lun " + str(lunid) + " already present in storage group " + name}
            fail("failed to attach lun " + str(lunid) + ": " + res.stderr)
        return {"changed": True, "msg": "attached lun " + str(lunid) + " to storage group " + name}

    if state == "absent":
        if not found:
            return {"changed": False, "msg": "lun " + str(lunid) + " not present in storage group " + name}
        res = ctx.run(["scli", "-u", sp_user, "-p", sp_password, "-d", sp_address, "-q", "detach alu " + str(lunid) + " from storage_group " + name], mutates=True)
        if res.rc != 0:
            fail("failed to detach lun " + str(lunid) + ": " + res.stderr)
        return {"changed": True, "msg": "detached lun " + str(lunid) + " from storage group " + name}

    fail("unsupported state: " + state)
