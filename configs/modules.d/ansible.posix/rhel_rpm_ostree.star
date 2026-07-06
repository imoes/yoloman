def main(ctx, params):
    # Verify that the platform is an rpm-ostree based system
    if not ctx.file_exists("/run/ostree-booted"):
        fail("Module rhel_rpm_ostree is only applicable for rpm-ostree based systems.")

    # Get parameters
    name = params.get("name", [])
    if not isinstance(name, list):
        name = [name]
    state = params.get("state", "present")
    if state == None:
        state = "present"

    # Map aliases: installed -> present, removed -> absent
    if state == "installed":
        state = "present"
    elif state == "removed":
        state = "absent"

    # Normalize packages to list of strings
    pkgs = []
    for item in name:
        if isinstance(item, list):
            pkgs.extend([str(x) for x in item])
        else:
            pkgs.append(str(item))

    # Build list of packages to act on
    to_operate = []
    if state in ["present", "latest"]:
        for pkg in pkgs:
            res = ctx.run(["rpm", "-q", pkg], mutates=False)
            if res.rc != 0:
                to_operate.append(pkg)
    elif state == "absent":
        for pkg in pkgs:
            res = ctx.run(["rpm", "-q", pkg], mutates=False)
            if res.rc == 0:
                to_operate.append(pkg)
    else:
        fail("Unsupported state: " + state)

    # No work needed?
    if not to_operate:
        return {"changed": False, "msg": "No changes made."}

    # In check_mode and need to change: return would-have message
    if ctx.check_mode:
        if state in ["present", "latest"]:
            msg = "would install package(s): " + " ".join(to_operate)
        else:
            msg = "would remove package(s): " + " ".join(to_operate)
        return {"changed": True, "msg": msg}

    # Perform the operation
    if state in ["present", "latest"]:
        # rpm-ostree install: note that rpm-ostree install doesn't exist in same way
        # Instead, we must fail because package installation isn't supported at runtime
        fail("The following packages are absent in the currently booted rpm-ostree commit: " + " ".join(to_operate))
    elif state == "absent":
        # rpm-ostree uninstall: not supported for booted system
        fail("The following packages are present in the currently booted rpm-ostree commit: " + " ".join(to_operate))
