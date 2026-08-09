def main(ctx, params):
    alias = params["alias"]
    name = params.get("name")
    policy_id = params.get("id")
    state = params.get("state", "present")

    # Mutual exclusion check
    if name and policy_id:
        fail("name and id are mutually exclusive")

    # Required args for present
    if state == "present":
        required = ["alert_recipients", "metric", "duration", "threshold"]
        for key in required:
            if key not in params:
                fail("missing required parameter for state=present: " + key)
        # Validate threshold range and multiple of 5
        threshold = params["threshold"]
        if threshold < 5 or threshold > 95 or (threshold % 5) != 0:
            fail("threshold must be between 5 and 95 and a multiple of 5")

    # Probing: List policies via jq for parsing
    token = os.environ.get("CLC_V2_API_TOKEN", "")
    if not token:
        fail("CLC_V2_API_TOKEN environment variable is required")

    # Get policies with jq parsing
    res = ctx.run(["curl", "-sS", "-X", "GET",
                   "-H", "Content-Type: application/json",
                   "-H", "Authorization: Bearer " + token,
                   "https://api.ctl.io/v2/alertPolicies/" + alias],
                  mutates=False)
    if res.rc != 0:
        fail("failed to list alert policies: " + res.stderr)

    # Parse JSON with jq if available
    res = ctx.run(["echo", res.stdout],
                  mutates=False)
    res = ctx.run(["jq", "-r", ".[] | \"\\(.id)\\t\\(.name)\""],
                  mutates=False)
    if res.rc != 0:
        fail("failed to parse alert policies with jq: " + res.stderr)

    # Build policies dict from jq output
    policies = {}
    lines = res.stdout.strip().split("\n") if res.stdout.strip() else []
    for line in lines:
        if not line.strip():
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        policies[parts[0]] = parts[1]

    # Determine if policy exists
    found_id = None
    if name:
        for pid, pname in policies.items():
            if pname == name:
                found_id = pid
                break
    elif policy_id:
        if policy_id in policies:
            found_id = policy_id
        else:
            found_id = None
    else:
        fail("either name or id must be provided")

    if state == "present":
        if found_id:
            # Update — assume changes unless identical (simplified for Starlark)
            # Full field comparison skipped due to JSON parsing limits
            changed = True
            if not ctx.check_mode:
                # Build JSON payload manually and POST with jq
                fail("update not fully implemented in Starlark without JSON lib")
            else:
                return {"changed": True, "msg": "would update alert policy"}
        else:
            # Create
            changed = True
            if not ctx.check_mode:
                fail("create not fully implemented in Starlark without JSON lib")
            else:
                return {"changed": True, "msg": "would create alert policy"}
    else:  # absent
        if found_id:
            changed = True
            if not ctx.check_mode:
                res = ctx.run(["curl", "-sS", "-X", "DELETE",
                               "-H", "Content-Type: application/json",
                               "-H", "Authorization: Bearer " + token,
                               "https://api.ctl.io/v2/alertPolicies/" + alias + "/" + found_id],
                              mutates=True)
                if res.rc != 0:
                    fail("failed to delete alert policy: " + res.stderr)
            else:
                return {"changed": True, "msg": "would delete alert policy"}
        else:
            return {"changed": False, "msg": "alert policy not found"}
