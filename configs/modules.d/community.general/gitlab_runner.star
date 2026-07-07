def main(ctx, params):
    # Extract parameters with defaults
    description = params["description"]
    state = params.get("state", "present")
    owned = params.get("owned", False)
    tag_list = params.get("tag_list", [])
    run_untagged = params.get("run_untagged", True)
    locked = params.get("locked", False)
    access_level = params.get("access_level")
    maximum_timeout = params.get("maximum_timeout", 3600)
    registration_token = params.get("registration_token")
    project = params.get("project")
    group = params.get("group")
    active = params.get("active", True)
    paused = params.get("paused", False)
    access_level_on_creation = params.get("access_level_on_creation", True)

    # Mutually exclusive checks (fail early)
    if project != None and owned != None and (project and owned):
        fail("options 'project' and 'owned' are mutually exclusive")
    if group != None and owned != None and (group and owned):
        fail("options 'group' and 'owned' are mutually exclusive")
    if project != None and group != None and (project and group):
        fail("options 'project' and 'group' are mutually exclusive")
    if active != None and paused != None:
        fail("options 'active' and 'paused' are mutually exclusive")

    # Authentication validation
    base_url = params.get("api_url")
    api_token = params.get("api_token") or params.get("api_oauth_token") or params.get("api_job_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    ca_path = params.get("ca_path")
    validate_certs = params.get("validate_certs", True)

    if not base_url:
        fail("required option 'api_url' is missing")
    if not api_token and (not api_username or not api_password):
        fail("one of api_token, api_oauth_token, api_job_token, or api_username+api_password is required")

    # Build gitlab CLI base arguments
    def gitlab_cli_args(cmd, extra_args=None):
        args = ["gitlab", "--url", base_url]
        if api_token:
            args += ["--token", api_token]
        elif api_username:
            args += ["--username", api_username, "--password", api_password]
        if not validate_certs:
            args.append("--no-verify-ssl")
        if ca_path:
            args += ["--ca-path", ca_path]
        args.append(cmd)
        if extra_args:
            args.extend(extra_args)
        return args

    # Helper: find runner by description via gitlab run list --json
    def find_runner(desc):
        list_cmd = ["run", "list", "--json"]
        if owned:
            list_cmd.append("--owned")
        elif project:
            list_cmd += ["--project", project]
        elif group:
            list_cmd += ["--group", group]
        res = ctx.run(gitlab_cli_args("run", list_cmd), mutates=False)
        if res.skipped:
            return None
        if res.rc != 0:
            fail("failed to list runners: " + res.stderr)
        # Parse JSON lines manually
        lines = res.stdout.strip().splitlines()
        for line in lines:
            if not line.strip():
                continue
            if '"description":"%s"' % desc in line:
                idx1 = line.find('"id":')
                if idx1 != -1:
                    idx2 = line.find(',', idx1)
                    if idx2 == -1:
                        idx2 = line.find('}', idx1)
                    if idx2 != -1:
                        rid_str = line[idx1+5:idx2].strip()
                        rid = int(rid_str)
                        return rid
        return None

    # Helper: get runner details by id
    def get_runner_details(rid):
        res = ctx.run(gitlab_cli_args("run", ["show", str(rid), "--json"]), mutates=False)
        if res.skipped:
            return None
        if res.rc != 0:
            return None
        return res.stdout.strip()

    # State logic
    if state == "absent":
        rid = find_runner(description)
        if rid == None:
            return {"changed": False, "msg": "Runner does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete runner %s" % description}
        res = ctx.run(gitlab_cli_args("run", ["delete", str(rid)]), mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete runner %s" % description}
        if res.rc != 0:
            fail("failed to delete runner: " + res.stderr)
        return {"changed": True, "msg": "Successfully deleted runner %s" % description}

    if state == "present":
        rid = find_runner(description)
        if rid != None and ctx.check_mode:
            return {"changed": True, "msg": "would update runner %s" % description}
        elif rid == None and ctx.check_mode:
            return {"changed": True, "msg": "would register runner %s" % description}

        # Build desired CLI arguments for register/update
        desired_flags = []
        desired_flags.append("--description=%s" % description)
        effective_active = active if active != None else (False if paused else True)
        desired_flags.append("--active=%s" % ("true" if effective_active else "false"))
        desired_flags.append("--locked=%s" % ("true" if locked else "false"))
        desired_flags.append("--run-untagged=%s" % ("true" if run_untagged else "false"))
        desired_flags.append("--maximum-timeout=%s" % str(maximum_timeout))
        if tag_list:
            desired_flags.append("--tag-list=%s" % ",".join(tag_list))

        if access_level:
            desired_flags.append("--access-level=%s" % ("not_protected" if access_level == "not_protected" else "ref_protected"))
        if project:
            desired_flags.append("--project=%s" % project)
        if group:
            desired_flags.append("--group=%s" % group)

        if rid == None:
            reg_cmd = ["register"] + desired_flags
            if registration_token:
                reg_cmd += ["--registration-token=%s" % registration_token]
            res = ctx.run(gitlab_cli_args("run", reg_cmd), mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would register runner %s" % description}
            if res.rc != 0:
                fail("failed to register runner: " + res.stderr)
            return {"changed": True, "msg": "Successfully created runner %s" % description}
        else:
            fail("gitlab_runner: update is not supported via gitlab CLI; use python-gitlab module or api_token with direct API")
