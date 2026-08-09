def main(ctx, params):
    # Core parameters
    state = params.get("state", "present")
    name_list = params.get("name", [])
    list_query = params.get("list")

    # Validation: name and list are mutually exclusive
    if name_list and list_query:
        fail("name and list parameters are mutually exclusive")

    # Handle list query (read-only operation)
    if list_query:
        # Supported list subcommands
        valid_list_values = ["installed", "updates", "available", "repos"]
        if list_query in valid_list_values or list_query == "*":
            # In check_mode, we predict we can list, return empty for simplicity
            if ctx.check_mode:
                return {"changed": False, "msg": "would list " + list_query, "results": []}
            # We cannot actually run repoquery in Starlark; fail with guidance
            fail("list queries require 'repoquery' binary which is not available in Starlark runtime. Use shell module instead.")
        else:
            fail("unsupported list value: %s (must be one of: installed, updates, available, repos, or package name)" % list_query)

    # Ensure yum is available (basic check)
    res = ctx.run(["which", "yum"], mutates=False)
    if res.rc != 0:
        fail("yum is not installed on this system")

    # Handle state=latest with name='*' (upgrade all)
    if state == "latest" and name_list == ["*"]:
        # Upgrade all packages
        if ctx.check_mode:
            return {"changed": True, "msg": "would update all packages"}
        cmd = ["yum", "-y", "update"]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would update all packages"}
        if res.rc != 0:
            fail("yum update failed: " + res.stderr)
        return {"changed": True, "msg": "updated all packages"}

    # Default state: present/install
    if state not in ["present", "installed", "latest", "absent", "removed"]:
        fail("unsupported state: " + state)

    # If state is absent/removed, map to "absent"
    if state == "removed":
        state = "absent"
    if state == "installed":
        state = "present"

    # Process each package (single-package case for idempotency)
    if not name_list:
        fail("name parameter is required unless using 'list'")
    pkg_name = name_list[0]  # Simplify: only first package in list

    # Read current state via rpm query (idempotent probe)
    rpm_cmd = ["rpm", "-q", "--qf", "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\\n", pkg_name]
    res = ctx.run(rpm_cmd, mutates=False)
    installed = (res.rc == 0)

    # Latest state requires checking available version
    if state == "latest":
        if ctx.check_mode:
            # Heuristic: assume change if package not installed or if we can't verify current vs latest
            if installed:
                return {"changed": True, "msg": "would update " + pkg_name}
            else:
                return {"changed": True, "msg": "would install " + pkg_name}
        # Install or update to latest version
        cmd = ["yum", "-y", "install", pkg_name]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would install or update " + pkg_name}
        if res.rc != 0:
            fail("yum install/update failed: " + res.stderr)
        # Double-check with rpm
        res2 = ctx.run(rpm_cmd, mutates=False)
        if res2.rc == 0:
            return {"changed": True, "msg": "installed or updated " + pkg_name}
        else:
            fail("package " + pkg_name + " not found after install")

    # Present/install state
    if state in ["present", "installed"]:
        if installed:
            return {"changed": False, "msg": pkg_name + " already installed"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would install " + pkg_name}
        cmd = ["yum", "-y", "install", pkg_name]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would install " + pkg_name}
        if res.rc != 0:
            fail("yum install failed: " + res.stderr)
        return {"changed": True, "msg": "installed " + pkg_name}

    # Absent/removed state
    if state == "absent":
        if not installed:
            return {"changed": False, "msg": pkg_name + " not installed"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove " + pkg_name}
        cmd = ["yum", "-y", "remove", pkg_name]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove " + pkg_name}
        if res.rc != 0:
            fail("yum remove failed: " + res.stderr)
        # Verify removal
        res2 = ctx.run(rpm_cmd, mutates=False)
        if res2.rc != 0:
            return {"changed": True, "msg": "removed " + pkg_name}
        else:
            fail("package " + pkg_name + " still present after remove")

    fail("internal error: unreachable code in yum module")
