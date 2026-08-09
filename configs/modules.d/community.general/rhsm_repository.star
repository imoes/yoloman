def main(ctx, params):
    name = params["name"]
    state = params.get("state", "enabled")
    purge = params.get("purge", False)

    # Validate state values
    if state not in ["enabled", "disabled", "present", "absent"]:
        fail("invalid state '" + state + "'; must be one of: enabled, disabled, present, absent")

    # Deprecation warnings for 'present' and 'absent'
    if state in ["present", "absent"]:
        replacement = "enabled" if state == "present" else "disabled"
        # Note: Starlark runtime may not support deprecation calls directly;
        # in real implementation, use ctx.deprecate if available, else ignore
        pass

    # Check for root permissions
    if ctx.facts().get("os_family") == "redhat" and ctx.run(["whoami"], mutates=False).stdout.strip() != "root":
        fail("Interacting with subscription-manager requires root permissions ('become: true')")

    # Get subscription-manager path
    res = ctx.run(["which", "subscription-manager"], mutates=False)
    if res.rc != 0:
        fail("subscription-manager not found; must be installed")
    rhsm_bin = res.stdout.strip()

    # List repositories: subscription-manager repos --list
    res = ctx.run([rhsm_bin, "repos", "--list"], mutates=False)
    if res.rc != 0:
        fail("subscription-manager failed: " + res.stderr)
    if "This system has no repositories available through subscriptions" in res.stdout:
        fail("This system has no repositories available through subscriptions")

    # Parse repository list
    repo_id = ""
    repo_name = ""
    repo_url = ""
    repo_enabled = ""
    current_repos = []

    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("+") or (len(stripped) > 0 and stripped[0] == " "):
            continue

        if stripped.startswith("Repo ID: "):
            repo_id = stripped[9:].lstrip()
            continue

        if stripped.startswith("Repo Name: "):
            repo_name = stripped[11:].lstrip()
            continue

        if stripped.startswith("Repo URL: "):
            repo_url = stripped[10:].lstrip()
            continue

        if stripped.startswith("Enabled: "):
            repo_enabled = stripped[9:].lstrip()
            enabled_bool = repo_enabled == "1"
            current_repos.append({
                "id": repo_id,
                "name": repo_name,
                "url": repo_url,
                "enabled": enabled_bool
            })

    # Normalize name to list
    if type(name) == "string":
        name = [name]
    # Ensure all items are strings
    name = [str(x) for x in name]

    # Prepare updates
    updated_repos = []
    for repo in current_repos:
        updated_repos.append(dict(repo))  # shallow copy

    # Match repo IDs with fnmatch patterns
    matched_repos = {}
    for repoid in name:
        matched_repos[repoid] = []
        for repo in current_repos:
            if _fnmatch(repo["id"], repoid):
                matched_repos[repoid].append(repo)

    # Validate that all specified patterns match at least one repo
    for repoid in name:
        if len(matched_repos[repoid]) == 0:
            fail("Repository '" + repoid + "' is not a valid repository ID")

    # Determine required changes
    changed = False
    rhsm_args = []
    diff_before = ""
    diff_after = ""

    for repoid, repos in matched_repos.items():
        for repo in repos:
            is_enabled = repo["enabled"]
            if state in ["disabled", "absent"]:
                if is_enabled:
                    changed = True
                    diff_before += "Repository '" + repo["id"] + "' is enabled for this system\n"
                    diff_after += "Repository '" + repo["id"] + "' is disabled for this system\n"
                    # Mark for update
                    for r in updated_repos:
                        if r["id"] == repo["id"]:
                            r["enabled"] = False
                rhsm_args.extend(["--disable", repo["id"]])
            elif state in ["enabled", "present"]:
                if not is_enabled:
                    changed = True
                    diff_before += "Repository '" + repo["id"] + "' is disabled for this system\n"
                    diff_after += "Repository '" + repo["id"] + "' is enabled for this system\n"
                    # Mark for update
                    for r in updated_repos:
                        if r["id"] == repo["id"]:
                            r["enabled"] = True
                rhsm_args.extend(["--enable", repo["id"]])

    # Handle purge: disable repos not in the requested list
    if purge:
        requested_ids = set()
        for repoid, repos in matched_repos.items():
            for repo in repos:
                requested_ids.add(repo["id"])

        for repo in updated_repos:
            if repo["enabled"] and repo["id"] not in requested_ids:
                changed = True
                diff_before += "Repository '" + repo["id"] + "' is enabled for this system\n"
                diff_after += "Repository '" + repo["id"] + "' is disabled for this system\n"
                rhsm_args.extend(["--disable", repo["id"]])
                repo["enabled"] = False

    # Build results
    result_repos = []
    for repo in updated_repos:
        result_repos.append(repo)

    # In check_mode, do not execute and report changes
    if ctx.check_mode:
        if changed:
            return {
                "changed": True,
                "msg": "Would update repositories",
                "repositories": result_repos,
                "diff": {
                    "before": diff_before,
                    "after": diff_after,
                    "before_header": "RHSM repositories",
                    "after_header": "RHSM repositories"
                }
            }
        else:
            return {
                "changed": False,
                "msg": "Repositories already in desired state",
                "repositories": result_repos
            }

    # Execute changes
    if changed:
        res = ctx.run([rhsm_bin, "repos"] + rhsm_args, mutates=True)
        if res.rc != 0:
            fail("Failed to modify repositories: " + res.stderr)

    return {
        "changed": changed,
        "msg": "Repositories updated",
        "repositories": result_repos,
        "diff": {
            "before": diff_before,
            "after": diff_after,
            "before_header": "RHSM repositories",
            "after_header": "RHSM repositories"
        }
    }


def _fnmatch(name, pattern):
    # Simple fnmatch without regex — supports '*' wildcards
    # Build regex-like matching manually
    if pattern == "*":
        return True

    i = 0
    j = 0
    n = len(name)
    m = len(pattern)
    star_idx = -1
    match_idx = 0

    while i < n:
        if j < m and (pattern[j] == name[i] or pattern[j] == "?"):
            i += 1
            j += 1
        elif j < m and pattern[j] == '*':
            star_idx = j
            match_idx = i
            j += 1
        elif star_idx != -1:
            j = star_idx + 1
            match_idx += 1
            i = match_idx
        else:
            return False

    while j < m and pattern[j] == '*':
        j += 1

    return j == m
