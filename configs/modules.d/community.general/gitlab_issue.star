def main(ctx, params):
    # Required parameters
    project = params["project"]
    title = params["title"]
    state = params.get("state", "present")
    state_filter = params.get("state_filter", "opened")
    if state not in ["present", "absent"]:
        fail("state must be 'present' or 'absent'")
    if state_filter not in ["opened", "closed"]:
        fail("state_filter must be 'opened' or 'closed'")

    # Optional parameters
    api_url = params.get("api_url")
    api_token = params.get("api_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    api_oauth_token = params.get("api_oauth_token")
    api_job_token = params.get("api_job_token")
    ca_path = params.get("ca_path")
    validate_certs = params.get("validate_certs", True)
    assignee_ids = params.get("assignee_ids")
    description = params.get("description")
    description_path = params.get("description_path")
    issue_type = params.get("issue_type", "issue")
    labels = params.get("labels")
    milestone_search = params.get("milestone_search")
    milestone_group_id = params.get("milestone_group_id")

    # Input validation: auth
    auth_count = 0
    if api_username != None:
        auth_count += 1
    if api_token != None:
        auth_count += 1
    if api_oauth_token != None:
        auth_count += 1
    if api_job_token != None:
        auth_count += 1
    if auth_count == 0:
        fail("One of api_username, api_token, api_oauth_token, or api_job_token is required.")
    if auth_count > 1:
        fail("Only one of api_username, api_token, api_oauth_token, or api_job_token can be provided.")
    if api_username != None and api_password == None:
        fail("api_password is required when using api_username.")

    # Description handling (file takes precedence)
    final_description = description
    if description_path != None and description_path != "":
        content = ctx.file_read(description_path)
        final_description = content

    # Build GitLab API command (using gitlab-cli if available, otherwise fail)
    # Note: We expect gitlab-cli to be installed; fail if not found.
    # Base command: gitlab issue ...
    base_argv = ["gitlab", "issue"]

    # Authentication arguments
    if api_url != None and api_url != "":
        base_argv.extend(["--url", api_url])
    if api_token != None and api_token != "":
        base_argv.extend(["--token", api_token])
    if api_username != None and api_username != "":
        base_argv.extend(["--username", api_username])
    if api_password != None and api_password != "":
        base_argv.extend(["--password", api_password])
    if api_oauth_token != None and api_oauth_token != "":
        base_argv.extend(["--oauth-token", api_oauth_token])
    if api_job_token != None and api_job_token != "":
        base_argv.extend(["--job-token", api_job_token])
    if ca_path != None and ca_path != "":
        base_argv.extend(["--ca-path", ca_path])
    if not validate_certs:
        base_argv.append("--no-verify")

    # Project and title (required for all operations)
    base_argv.extend(["--project", project, "--title", title])

    # State_filter for listing (used when state=present)
    if state == "present":
        base_argv.append("--state")
        base_argv.append(state_filter)

    # Common options
    if issue_type != "issue":
        base_argv.extend(["--type", issue_type])
    if final_description != None and final_description != "":
        # Use --description flag if supported by gitlab-cli
        base_argv.extend(["--description", final_description])

    # Labels: join with comma (gitlab-cli expects comma-separated)
    if labels != None and len(labels) > 0:
        base_argv.extend(["--labels", ",".join(labels)])

    # Milestone: --milestone and --milestone-group
    if milestone_search != None and milestone_search != "":
        base_argv.extend(["--milestone", milestone_search])
    if milestone_group_id != None and milestone_group_id != "":
        base_argv.extend(["--milestone-group", milestone_group_id])

    # Assignees: gitlab-cli expects comma-separated usernames (no @)
    if assignee_ids != None and len(assignee_ids) > 0:
        base_argv.extend(["--assignees", ",".join(assignee_ids)])

    # Operation logic
    if state == "present":
        # Probe: list issues matching title and state_filter
        probe_argv = base_argv + ["--list"]
        probe = ctx.run(probe_argv)
        if probe.rc != 0:
            fail("Failed to list issues: " + probe.stderr)
        # Parse output: assume one issue per line in JSON or simple format
        lines = [l.strip() for l in probe.stdout.splitlines() if l.strip() != ""]
        existing_issues = [l for l in lines if l != ""]
        # Check if exactly one matches (gitlab-cli may return just the issue IIDs)
        # If no issues exist, create
        if len(existing_issues) == 0:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create issue '%s' in project '%s'" % (title, project)}
            create_argv = base_argv + ["--create"]
            create_res = ctx.run(create_argv)
            if create_res.skipped:
                return {"changed": True, "msg": "would create issue '%s' in project '%s'" % (title, project)}
            if create_res.rc != 0:
                fail("Failed to create issue: " + create_res.stderr)
            return {"changed": True, "msg": "Created issue '%s' in project '%s'" % (title, project)}
        # If exactly one exists, update if needed
        if len(existing_issues) == 1:
            # gitlab-cli update: gitlab issue --update --project ... --title ...
            # We compare current vs desired; for now assume any existing needs update if params differ.
            # In a minimal implementation, always attempt update if state=present
            update_argv = base_argv + ["--update"]
            update_res = ctx.run(update_argv)
            if ctx.check_mode:
                return {"changed": True, "msg": "would update issue '%s' in project '%s'" % (title, project)}
            if update_res.skipped:
                return {"changed": True, "msg": "would update issue '%s' in project '%s'" % (title, project)}
            if update_res.rc != 0:
                fail("Failed to update issue: " + update_res.stderr)
            return {"changed": True, "msg": "Updated issue '%s' in project '%s'" % (title, project)}
        # Multiple matches: fail
        fail("Multiple issues found matching title '%s' and state '%s'; cannot proceed." % (title, state_filter))
    else:  # state == "absent"
        # Probe: list issues matching title and state_filter
        probe_argv = base_argv + ["--list"]
        probe = ctx.run(probe_argv)
        if probe.rc != 0:
            fail("Failed to list issues: " + probe.stderr)
        lines = [l.strip() for l in probe.stdout.splitlines() if l.strip() != ""]
        existing_issues = [l for l in lines if l != ""]
        if len(existing_issues) == 0:
            return {"changed": False, "msg": "Issue '%s' does not exist or has already been deleted." % title}
        # One or more: delete the first one (gitlab-cli will fail if multiple match)
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete issue '%s' in project '%s'" % (title, project)}
        delete_argv = base_argv + ["--delete"]
        delete_res = ctx.run(delete_argv)
        if delete_res.skipped:
            return {"changed": True, "msg": "would delete issue '%s' in project '%s'" % (title, project)}
        if delete_res.rc != 0:
            fail("Failed to delete issue: " + delete_res.stderr)
        return {"changed": True, "msg": "Deleted issue '%s' in project '%s'" % (title, project)}
