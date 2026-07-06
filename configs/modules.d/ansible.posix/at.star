def main(ctx, params):
    # Validate required parameters for present state
    state = params.get("state", "present")
    if state == "present":
        if "count" not in params or "units" not in params:
            fail("present state requires count and units")

    # Check for mutually exclusive options
    has_command = "command" in params
    has_script_file = "script_file" in params
    if has_command and has_script_file:
        fail("command and script_file are mutually exclusive")

    if not has_command and not has_script_file:
        fail("one of command or script_file is required")

    at_cmd = ctx.run(["which", "at"], mutates=False)
    if at_cmd.rc != 0:
        fail("at command not found")

    # Create temporary script file if command provided
    script_file = None
    if "command" in params:
        # Use a simple path in /tmp (no os module in Starlark)
        script_file = "/tmp/at_" + str(hash(params["command"]))
        script_content = params["command"] + "\n"
        changed = ctx.file_write(script_file, script_content, "0600")
        # We ignore return value here because write may fail but we'll catch that in the job creation
        # In check_mode, ctx.file_write returns False but we don't mutate anyway
    else:
        script_file = params["script_file"]
        if not ctx.file_exists(script_file):
            fail("script_file does not exist: " + script_file)

    result = {"changed": False, "state": state}

    # Handle absent state
    if state == "absent":
        # Get current atq jobs
        atq_res = ctx.run(["atq"], mutates=False)
        if atq_res.rc != 0:
            fail("failed to list at jobs: " + atq_res.stderr)

        # Read script content for comparison
        script_content = ctx.file_read(script_file).strip() if ctx.file_exists(script_file) else ""

        # Find matching jobs
        job_lines = atq_res.stdout.splitlines()
        matching_jobs = []
        for line in job_lines:
            if not line.strip():
                continue
            parts = line.strip().split()
            if len(parts) < 1:
                continue
            job_id = parts[0]

            # Check job content
            atc_res = ctx.run(["at", "-c", job_id], mutates=False)
            if atc_res.rc == 0 and script_content in atc_res.stdout:
                matching_jobs.append(job_id)

        # Delete matching jobs
        for job_id in matching_jobs:
            if not ctx.check_mode:
                delete_res = ctx.run(["at", "-r", job_id], mutates=True)
                if delete_res.rc != 0:
                    fail("failed to delete job " + job_id + ": " + delete_res.stderr)
            result["changed"] = True

        # Clean up temporary file if created
        if "command" in params and script_file and script_file.startswith("/tmp/at_"):
            if not ctx.check_mode:
                if ctx.file_exists(script_file):
                    ctx.file_write(script_file, "", "0600")
            result["changed"] = True

        return result

    # Handle present state

    # Check unique constraint
    if params.get("unique", False):
        atq_res = ctx.run(["atq"], mutates=False)
        if atq_res.rc == 0:
            script_content = ctx.file_read(script_file).strip() if ctx.file_exists(script_file) else ""
            job_lines = atq_res.stdout.splitlines()
            for line in job_lines:
                if not line.strip():
                    continue
                parts = line.strip().split()
                if len(parts) < 1:
                    continue
                job_id = parts[0]
                atc_res = ctx.run(["at", "-c", job_id], mutates=False)
                if atc_res.rc == 0 and script_content in atc_res.stdout:
                    # Found matching job, do not add new one
                    if "command" in params and script_file and script_file.startswith("/tmp/at_"):
                        if not ctx.check_mode and ctx.file_exists(script_file):
                            ctx.file_write(script_file, "", "0600")
                    return {"changed": False, "state": state}

    # Schedule new job
    count = params["count"]
    units = params["units"]
    job_cmd = ["at", "-f", script_file, "now", "+", str(count), units]

    if ctx.check_mode:
        return {"changed": True, "state": state, "msg": "would schedule at job"}

    at_res = ctx.run(job_cmd, mutates=True)
    if at_res.rc != 0:
        fail("failed to schedule at job: " + at_res.stderr)

    result["changed"] = True
    result["script_file"] = script_file
    result["count"] = count
    result["units"] = units

    # Clean up temporary file if created
    if "command" in params and script_file and script_file.startswith("/tmp/at_"):
        if ctx.file_exists(script_file):
            ctx.file_write(script_file, "", "0600")

    return result
