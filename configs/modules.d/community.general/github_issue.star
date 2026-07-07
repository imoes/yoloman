def main(ctx, params):
    organization = params["organization"]
    repo = params["repo"]
    issue = params["issue"]
    action = params.get("action", "get_status")

    if action != "get_status":
        fail("unsupported action: " + action)

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/vnd.github.v3+json",
    }

    # Build URL without shell interpolation
    url = "https://api.github.com/repos/" + organization + "/" + repo + "/issues/" + str(issue)
    # ctx.run does not parse URLs; we construct raw HTTP request manually via curl
    # Use curl to get JSON from GitHub API
    res = ctx.run([
        "curl", "-s", "-S",
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/vnd.github.v3+json",
        url
    ], mutates=False)

    if res.rc != 0:
        fail("curl failed for " + url + ": " + res.stderr)

    # Parse JSON manually: extract "state" field
    # We cannot use json module, so parse with string search
    stdout = res.stdout
    state = None

    # Simple state extraction: look for '"state":"...' pattern
    key = '"state":"'
    idx = stdout.find(key)
    if idx != -1:
        start = idx + len(key)
        end = stdout.find('"', start)
        if end != -1:
            state = stdout[start:end]

    if state == None:
        fail("could not parse issue state from API response")

    # In check_mode, we still need to report changed=True to match original behavior
    # Original: in check_mode, changed=True; otherwise changed=True + issue_status
    # However, original also has changed=True even when no state change occurs (bug?), but
    # per contract, changed should be True only if something changed — but this is an info module.
    # Since the original module always returns changed=True for get_status, we do the same.
    # Per Ansible module conventions, *_info modules should set changed=False.
    # But original code explicitly sets changed=True, so we replicate that behavior.
    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "fetched issue " + str(issue) + " status",
            "data": {"issue_status": state}
        }

    return {
        "changed": True,
        "msg": "fetched issue " + str(issue) + " status",
        "data": {"issue_status": state}
    }
