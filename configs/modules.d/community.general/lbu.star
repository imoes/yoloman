def main(ctx, params):
    commit = params.get("commit", False)
    exclude_list = params.get("exclude", [])
    include_list = params.get("include", [])

    def run_lbu(*args):
        res = ctx.run(["lbu"] + list(args))
        if res.rc != 0:
            fail("lbu command failed: " + res.stderr)
        return res.stdout

    update = False

    # Check if any include/exclude paths need to be added
    for param_name in ["include", "exclude"]:
        paths_list = params.get(param_name, [])
        if paths_list:
            # List current paths with -l flag
            current_paths = run_lbu(param_name, "-l").split("\n")
            for path in paths_list:
                normalized = "/" + path
                # Normalize leading slash handling
                if normalized.startswith("//"):
                    normalized = normalized[1:]
                # Remove leading slash for comparison with lbu output
                normalized = normalized.lstrip("/")
                if normalized not in current_paths:
                    update = True
                    break
        if update:
            break

    # Determine if commit is needed
    commit_needed = False
    if commit:
        if update:
            commit_needed = True
        else:
            # Check if there are uncommitted changes
            status_out = run_lbu("status")
            if status_out.strip():
                commit_needed = True

    # Check mode handling
    if ctx.check_mode:
        return {"changed": update or commit_needed, "msg": "check mode"}

    changed = False

    # Update include/exclude lists
    for param_name in ["include", "exclude"]:
        paths_list = params.get(param_name, [])
        if paths_list:
            run_lbu(param_name, *paths_list)
            changed = True

    # Commit if needed
    if commit_needed:
        run_lbu("commit")
        changed = True

    return {"changed": changed, "msg": "lbu operation completed"}
