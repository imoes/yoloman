def _get_repo_states(ctx):
    res = ctx.run([
        "/usr/bin/dnf", "repolist", "--all", "--verbose"
    ], mutates=False)
    if res.rc != 0:
        fail("dnf repolist failed: " + res.stderr)
    
    repos = {}
    last_repo = ""
    for line in res.stdout.split("\n"):
        stripped = line.strip()
        if stripped.startswith("Repo-id:") and ":" in stripped:
            if last_repo != "":
                fail("dnf repolist parse failure: parsed another repo id before next status")
            last_repo = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("Repo-status:") and ":" in stripped:
            if last_repo == "":
                fail("dnf repolist parse failure: parsed status before repo id")
            status = stripped.split(":", 1)[1].strip()
            repos[last_repo] = status
            last_repo = ""
    return repos


def _pack_repo_states(states):
    enabled = []
    disabled = []
    for repo_id in states:
        if states[repo_id] == "enabled":
            enabled.append(repo_id)
        else:
            disabled.append(repo_id)
    enabled = sorted(enabled)
    disabled = sorted(disabled)
    return {"enabled": enabled, "disabled": disabled}


def main(ctx, params):
    dnf_bin = "/usr/bin/dnf"
    if not ctx.file_exists(dnf_bin):
        fail(dnf_bin + " was not found")
    
    repo_ids = params.get("name", [])
    if not isinstance(repo_ids, list):
        fail("name must be a list")
    
    state = params.get("state", "enabled")
    if state not in ["enabled", "disabled"]:
        fail("state must be 'enabled' or 'disabled'")
    
    repo_states = _get_repo_states(ctx)
    repo_states_pre = _pack_repo_states(repo_states)
    
    to_change = []
    for repo_id in repo_ids:
        if repo_id not in repo_states:
            fail("did not find repo with ID '" + repo_id + "' in dnf repolist --all --verbose")
        if repo_states[repo_id] != state:
            to_change.append(repo_id)
    
    changed = len(to_change) > 0
    changed_repos = to_change
    
    if changed:
        if ctx.check_mode:
            repo_states_post = repo_states_pre
            return {
                "changed": True,
                "msg": "would " + ("enable" if state == "enabled" else "disable") + " repositories: " + ", ".join(to_change),
                "repo_states_pre": repo_states_pre,
                "repo_states_post": repo_states_pre,
                "changed_repos": changed_repos
            }
        else:
            res = ctx.run([
                dnf_bin, "config-manager", "--set-" + state
            ] + to_change, mutates=True)
            if res.skipped:
                repo_states_post = repo_states_pre
                return {
                    "changed": True,
                    "msg": "would " + ("enable" if state == "enabled" else "disable") + " repositories: " + ", ".join(to_change),
                    "repo_states_pre": repo_states_pre,
                    "repo_states_post": repo_states_pre,
                    "changed_repos": changed_repos
                }
            if res.rc != 0:
                fail("dnf config-manager failed: " + res.stderr)
    
    repo_states_post = _pack_repo_states(_get_repo_states(ctx))
    
    if changed and not ctx.check_mode:
        for repo_id in to_change:
            repo_states_dict = {}
            for s in repo_states_post["enabled"]:
                repo_states_dict[s] = "enabled"
            for s in repo_states_post["disabled"]:
                repo_states_dict[s] = "disabled"
            if repo_states_dict.get(repo_id) != state:
                fail("dnf config-manager failed to make '" + repo_id + "' " + state)
    
    return {
        "changed": changed,
        "msg": "repositories processed: " + ", ".join(changed_repos) if changed else "no repositories to change",
        "repo_states_pre": repo_states_pre,
        "repo_states_post": repo_states_post,
        "changed_repos": changed_repos
    }
