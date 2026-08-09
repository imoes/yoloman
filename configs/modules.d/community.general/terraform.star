def main(ctx, params):
    project_path = params["project_path"]
    binary_path = params.get("binary_path")
    plugin_paths = params.get("plugin_paths")
    workspace = params.get("workspace", "default")
    purge_workspace = params.get("purge_workspace", False)
    state = params.get("state", "present")
    variables = params.get("variables") or {}
    complex_vars = params.get("complex_vars", False)
    variables_files = params.get("variables_files")
    plan_file = params.get("plan_file")
    state_file = params.get("state_file")
    force_init = params.get("force_init", False)
    backend_config = params.get("backend_config")
    backend_config_files = params.get("backend_config_files")
    init_reconfigure = params.get("init_reconfigure", False)
    overwrite_init = params.get("overwrite_init", True)
    check_destroy = params.get("check_destroy", False)
    provider_upgrade = params.get("provider_upgrade", False)
    parallelism = params.get("parallelism")
    lock = params.get("lock", True)
    lock_timeout = params.get("lock_timeout")
    targets = params.get("targets", [])

    # Determine terraform binary
    if binary_path != None:
        bin_path = binary_path
    else:
        res = ctx.run(["which", "terraform"])
        if res.rc != 0:
            fail("terraform binary not found in PATH")
        bin_path = res.stdout.strip()

    # Version check
    res = ctx.run([bin_path, "version", "-json"])
    if res.rc != 0:
        fail("Failed to get terraform version: " + res.stderr)
    version_str = res.stdout.strip()
    start = version_str.find('"terraform_version"')
    if start == -1:
        fail("Could not parse terraform version: missing terraform_version field")
    start = version_str.find(':', start)
    if start == -1:
        fail("Could not parse terraform version: no value after terraform_version")
    start += 1
    while start < len(version_str) and (version_str[start] == ' ' or version_str[start] == '"'):
        start += 1
    end = start
    while end < len(version_str) and version_str[end] != '"':
        end += 1
    terraform_version = version_str[start:end]

    # Determine command args based on version
    if terraform_version < "0.15.0":
        destroy_args = ["destroy", "-no-color", "-force"]
        apply_args = ["apply", "-no-color", "-input=false", "-auto-approve=true"]
    else:
        destroy_args = ["destroy", "-no-color", "-auto-approve"]
        apply_args = ["apply", "-no-color", "-input=false", "-auto-approve"]

    # Validate project path
    if not ctx.file_exists(project_path):
        fail("Path for Terraform project '%s' doesn't exist" % project_path)
    stat_info = ctx.stat(project_path)
    if stat_info == None or not stat_info.is_dir:
        fail("Path for Terraform project '%s' is not a directory" % project_path)

    # Init if needed
    if force_init:
        tfstate_path = project_path + "/.terraform/terraform.tfstate"
        if overwrite_init or not ctx.file_exists(tfstate_path):
            init_cmd = [bin_path, "init", "-input=false", "-no-color"]
            if backend_config != None:
                for key, val in backend_config.items():
                    init_cmd.extend(["-backend-config", str(key) + "=" + str(val)])
            if backend_config_files != None:
                for f in backend_config_files:
                    init_cmd.extend(["-backend-config", f])
            if init_reconfigure:
                init_cmd.append("-reconfigure")
            if provider_upgrade:
                init_cmd.append("-upgrade")
            if plugin_paths != None:
                for p in plugin_paths:
                    init_cmd.extend(["-plugin-dir", p])
            init_res = ctx.run(init_cmd, mutates=True, ok_codes=[0])
            if init_res.rc != 0:
                fail("terraform init failed: " + init_res.stderr)

    # Workspace handling
    ws_res = ctx.run([bin_path, "workspace", "list", "-no-color"], ok_codes=[0,1])
    current_ws = "default"
    all_workspaces = []
    if ws_res.rc == 0:
        for line in ws_res.stdout.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("* "):
                current_ws = stripped[2:]
                all_workspaces.append(current_ws)
            else:
                all_workspaces.append(stripped)

    if current_ws != workspace:
        if workspace not in all_workspaces:
            ctx.run([bin_path, "workspace", "new", workspace, "-no-color"], mutates=True)
        else:
            ctx.run([bin_path, "workspace", "select", workspace, "-no-color"])

    # Build command based on state
    command = [bin_path]
    if state == "absent":
        command.extend(destroy_args)
    else:
        command.extend(apply_args)

    if state == "present" and parallelism != None:
        command.append("-parallelism=" + str(parallelism))
    if lock != None:
        command.append("-lock=" + ("true" if lock else "false"))
    if lock_timeout != None:
        command.append("-lock-timeout=" + str(lock_timeout) + "s")

    for t in targets:
        command.extend(["-target", t])

    # Variables processing
    variables_args = []
    if variables != None:
        if complex_vars:
            def format_vars_complex(vars_dict):
                if type(vars_dict) == "dict":
                    out_parts = []
                    for k, v in vars_dict.items():
                        if type(v) == "dict":
                            out_parts.append(k + "=" + format_vars_complex(v))
                        elif type(v) == "list":
                            out_parts.append(k + "=" + format_vars_complex(v))
                        else:
                            out_parts.append(format_args_simple(k, v))
                    return "{" + ",".join(out_parts) + "}"
                elif type(vars_dict) == "list":
                    item_parts = []
                    for item in vars_dict:
                        if type(item) == "dict":
                            item_parts.append("{" + format_vars_complex(item) + "}")
                        elif type(item) == "list":
                            item_parts.append(format_vars_complex(item))
                        else:
                            item_parts.append(format_args_simple(None, item))
                    return "[" + ",".join(item_parts) + "]"
                else:
                    return format_args_simple(None, vars_dict)

            def format_args_simple(key, value):
                if type(value) == "string":
                    # quote string and escape backslashes and quotes
                    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
                    return '"' + escaped + '"'
                elif type(value) == "bool":
                    return "true" if value else "false"
                else:
                    return str(value)

            for k, v in variables.items():
                if type(v) == "dict":
                    variables_args.extend(["-var", k + "=" + format_vars_complex(v)])
                elif type(v) == "list":
                    variables_args.extend(["-var", k + "=" + format_vars_complex(v)])
                elif type(v) == "string":
                    variables_args.extend(["-var", k + "=" + v])
                else:
                    variables_args.extend(["-var", k + "=" + format_args_simple(None, v)])
        else:
            for k, v in variables.items():
                variables_args.extend(["-var", k + "=" + str(v)])

    if variables_files != None:
        for f in variables_files:
            variables_args.extend(["-var-file", f])

    # Build plan if needed
    needs_application = False
    if state == "present" and plan_file == None:
        # create temp plan file
        res = ctx.run(["mktemp", "-t", "ansible-terraform-XXXXXX.tfplan"])
        if res.rc != 0:
            fail("Failed to create temp plan file")
        plan_file = res.stdout.strip()

        plan_cmd = [bin_path, "plan", "-input=false", "-no-color", "-detailed-exitcode", "-out", plan_file]
        plan_cmd.extend(variables_args)
        if state_file != None:
            plan_cmd.extend(["-state", state_file])
        for t in targets:
            plan_cmd.extend(["-target", t])

        plan_res = ctx.run(plan_cmd, ok_codes=[0,1,2])
        if plan_res.rc == 0:
            needs_application = False
        elif plan_res.rc == 1:
            fail("Terraform plan failed: " + plan_res.stderr)
        elif plan_res.rc == 2:
            needs_application = True
        else:
            fail("Unexpected terraform plan exit code: " + str(plan_res.rc))
    else:
        needs_application = True

    # State-specific command adjustments
    if state == "absent":
        command.extend(variables_args)
    elif state == "present" and plan_file != None:
        if ctx.file_exists(project_path + "/" + plan_file):
            command.append(project_path + "/" + plan_file)
        elif ctx.file_exists(plan_file):
            command.append(plan_file)
        else:
            fail("Could not find plan_file " + plan_file)
    elif state == "present":
        command.append(plan_file)

    # Run the command
    if state == "absent" or (state == "present" and needs_application and not ctx.check_mode):
        run_res = ctx.run(command, mutates=True)
        if run_res.rc != 0:
            fail("Terraform command failed: " + run_res.stderr)

    # Get outputs
    out_cmd = [bin_path, "output", "-no-color", "-json"]
    if state_file != None:
        out_cmd.extend(["-state", state_file])
    out_res = ctx.run(out_cmd, ok_codes=[0,1])
    outputs = {}
    if out_res.rc == 0:
        outputs = {}

    # Handle check_mode diffs
    diff = {}
    if ctx.check_mode and state != "absent" and plan_file != None:
        diff_cmd = [bin_path, "show", "-json", plan_file]
        diff_res = ctx.run(diff_cmd, ok_codes=[0,1])
        if diff_res.rc == 0:
            diff = {"before": {}, "after": {}}

    # Restore workspace
    if current_ws != workspace:
        ctx.run([bin_path, "workspace", "select", current_ws, "-no-color"])

    # Purge workspace if needed
    if state == "absent" and workspace != "default" and purge_workspace:
        ctx.run([bin_path, "workspace", "delete", workspace, "-no-color"], mutates=True)

    # Determine changed status
    changed = False
    if state == "absent":
        changed = True
    elif state == "present" and not ctx.check_mode:
        if plan_file != None and needs_application:
            changed = True
        else:
            changed = True
    elif ctx.check_mode:
        if state == "present" and plan_file == None and needs_application:
            changed = True
        elif state == "present" and plan_file != None:
            changed = True
        elif state == "planned":
            changed = True

    # Prepare result
    result = {
        "changed": changed,
        "msg": "",
        "data": {
            "state": state,
            "workspace": workspace,
            "outputs": outputs,
            "stdout": "",
            "stderr": "",
            "command": " ".join(command),
            "diff": diff,
        }
    }

    # Get actual stdout/stderr from last run if available
    if state == "absent" and not ctx.check_mode:
        res = ctx.run(command, ok_codes=[0,1])
        result["data"]["stdout"] = res.stdout
        result["data"]["stderr"] = res.stderr
    elif state == "present" and plan_file != None and not ctx.check_mode:
        res = ctx.run(command, ok_codes=[0,1])
        result["data"]["stdout"] = res.stdout
        result["data"]["stderr"] = res.stderr
    elif ctx.check_mode:
        result["msg"] = "would run terraform " + state

    return result
