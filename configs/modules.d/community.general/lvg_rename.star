def main(ctx, params):
    vg = params["vg"]
    vg_new = params["vg_new"]

    # Check if vg and vg_new are provided (already required in argspec)
    if vg == None or vg == "":
        fail("vg is required and must not be empty")
    if vg_new == None or vg_new == "":
        fail("vg_new is required and must not be empty")

    # Get vgs binary path
    vgs_cmd = ctx.run(["which", "vgs"])
    if vgs_cmd.rc != 0:
        fail("vgs command not found")
    vgs_path = vgs_cmd.stdout.strip()

    # Read current volume groups
    res = ctx.run([vgs_path, "--noheadings", "--separator", ";", "-o", "vg_name,vg_uuid"])
    if res.rc != 0:
        fail("failed to list volume groups: " + res.stderr)

    vg_list = []
    for line in res.stdout.strip().split("\n"):
        if line.strip() == "":
            continue
        parts = line.strip().split(";", 1)
        if len(parts) == 2:
            vg_name, vg_uuid = parts
            vg_list.append(vg_name.strip())
            vg_list.append(vg_uuid.strip())

    # Normalize vg and vg_new (strip /dev/ prefix)
    dev_prefix = "/dev/"
    if vg.startswith(dev_prefix):
        vg_id = vg[len(dev_prefix):]
    else:
        vg_id = vg

    if vg_new.startswith(dev_prefix):
        vg_new_id = vg_new[len(dev_prefix):]
    else:
        vg_new_id = vg_new

    # Check existence
    old_vg_exists = vg_id in vg_list
    new_vg_exists = vg_new_id in vg_list

    if old_vg_exists:
        if new_vg_exists:
            fail("The new VG name (%s) is already in use." % vg_new)
        # Proceed to rename
    else:
        if new_vg_exists:
            return {"changed": False, "msg": "The new VG (%s) already exists, nothing to do." % vg_new}
        else:
            fail("Both current (%s) and new (%s) VG are missing." % (vg, vg_new))

    # Get vgrename binary
    vgrename_cmd = ctx.run(["which", "vgrename"])
    if vgrename_cmd.rc != 0:
        fail("vgrename command not found")
    vgrename_path = vgrename_cmd.stdout.strip()

    if ctx.check_mode:
        return {"changed": True, "msg": "Running in check mode. The module would rename VG %s to %s." % (vg, vg_new)}

    # Execute rename
    res = ctx.run([vgrename_path, vg_id, vg_new_id], mutates=True)
    if res.rc != 0:
        fail("failed to rename VG: " + res.stderr)

    return {"changed": True, "msg": res.stdout.strip() if res.stdout.strip() else "VG renamed successfully"}
