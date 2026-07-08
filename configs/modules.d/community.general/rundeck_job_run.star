def main(ctx, params):
    url = params["url"]
    api_token = params["api_token"]
    job_id = params["job_id"]
    job_options = params.get("job_options", {})
    filter_nodes = params.get("filter_nodes", "")
    run_at_time = params.get("run_at_time", "")
    loglevel = params.get("loglevel", "info").upper()
    wait_execution = params.get("wait_execution", True)
    wait_execution_delay = params.get("wait_execution_delay", 5)
    wait_execution_timeout = params.get("wait_execution_timeout", 120)
    abort_on_timeout = params.get("abort_on_timeout", False)
    api_version = params.get("api_version", 39)
    url_username = params.get("url_username")
    url_password = params.get("url_password")
    use_proxy = params.get("use_proxy", True)
    validate_certs = params.get("validate_certs", True)
    http_agent = params.get("http_agent", "ansible-httpget")
    force_basic_auth = params.get("force_basic_auth", False)

    # Validate API version
    if api_version < 14:
        fail("API version should be at least 14")

    # Validate job options are strings
    for k, v in job_options.items():
        if type(v) != "string":
            fail("Job option '%s' value must be a string" % k)

    # Build job run endpoint
    endpoint = "job/%s/run" % job_id

    # Build request body as form data
    data_parts = []
    data_parts.append("loglevel=" + loglevel)
    for ok, ov in job_options.items():
        data_parts.append("options[" + ok + "]=" + ov)
    if run_at_time != "":
        data_parts.append("runAtTime=" + run_at_time)
    if filter_nodes != "":
        data_parts.append("filter=" + filter_nodes)

    body = "&".join(data_parts)

    # Build URL
    if not url.endswith("/"):
        url = url + "/"

    full_url = url + "api/" + str(api_version) + "/" + endpoint

    # Send job run request
    res = ctx.run(
        [
            "curl", "-s", "-X", "POST",
            "-H", "X-Rundeck-Auth-Token: " + api_token,
            "-H", "Content-Type: application/x-www-form-urlencoded",
            "-d", body,
            full_url
        ],
        mutates=True
    )

    if res.rc != 0:
        fail("Failed to run job: " + res.stderr)

    # Parse response - extract id using simple string search
    out = res.stdout.strip()
    exec_id = -1
    id_pos = out.find('"id":')
    if id_pos != -1:
        rest = out[id_pos + 5:]
        end_quote = rest.find('"')
        if end_quote == -1:
            # Try integer parsing
            end_pos = rest.find(',')
            if end_pos == -1:
                end_pos = rest.find('}')
            if end_pos != -1:
                exec_id_str = rest[:end_pos].strip()
                if exec_id_str.isdigit():
                    exec_id = int(exec_id_str)
        else:
            # Handle quoted id
            exec_id_str = rest[:end_quote].strip()
            if exec_id_str.isdigit():
                exec_id = int(exec_id_str)

    if exec_id == -1:
        # Fallback: try to find number after id:
        id_pos = out.find('"id" :')
        if id_pos != -1:
            rest = out[id_pos + 6:]
            end_pos = rest.find(',')
            if end_pos == -1:
                end_pos = rest.find('}')
            if end_pos != -1:
                exec_id_str = rest[:end_pos].strip()
                if exec_id_str.isdigit():
                    exec_id = int(exec_id_str)

    if not wait_execution:
        return {
            "changed": True,
            "msg": "Job run sent successfully!",
            "execution_info": {"id": exec_id}
        }

    # Wait for execution
    due = ctx.now() + wait_execution_timeout * 1000
    poll_interval_ms = wait_execution_delay * 1000

    status_response = {}
    while True:
        now = ctx.now()
        if now >= due:
            break

        # Get execution status
        exec_status_res = ctx.run(
            [
                "curl", "-s",
                "-H", "X-Rundeck-Auth-Token: " + api_token,
                url + "api/" + str(api_version) + "/execution/" + str(exec_id)
            ],
            mutates=False
        )
        if exec_status_res.rc != 0:
            fail("Failed to get execution status: " + exec_status_res.stderr)

        status_out = exec_status_res.stdout.strip()
        status = ""
        status_pos = status_out.find('"status":')
        if status_pos != -1:
            rest = status_out[status_pos + 9:]
            # Find closing quote
            end_quote = rest.find('"')
            if end_quote != -1:
                status = rest[1:end_quote]

        if status == "":
            status_pos = status_out.find('"status" :')
            if status_pos != -1:
                rest = status_out[status_pos + 10:]
                end_quote = rest.find('"')
                if end_quote != -1:
                    status = rest[1:end_quote]

        if status == "succeeded":
            # Get output
            output_res = ctx.run(
                [
                    "curl", "-s",
                    "-H", "X-Rundeck-Auth-Token: " + api_token,
                    url + "api/" + str(api_version) + "/execution/" + str(exec_id) + "/output"
                ],
                mutates=False
            )
            if output_res.rc == 0:
                # Extract log entries roughly
                log_output = output_res.stdout
                status_response["output"] = log_output

            status_response["status"] = "succeeded"
            return {
                "changed": True,
                "msg": "Job execution succeeded!",
                "execution_info": status_response
            }
        elif status == "failed":
            status_response["status"] = "failed"
            return {
                "changed": True,
                "msg": "Job execution failed",
                "execution_info": status_response
            }
        elif status == "aborted":
            status_response["status"] = "aborted"
            return {
                "changed": True,
                "msg": "Job execution was aborted",
                "execution_info": status_response
            }
        elif status == "scheduled":
            status_response["status"] = "scheduled"
            return {
                "changed": True,
                "msg": "Job scheduled to run at %s" % run_at_time,
                "execution_info": status_response
            }

        # Save current status for timeout case
        status_response = {"status": status}

        # Wait before next poll
        ctx.sleep(poll_interval_ms // 1000)

    # Timeout occurred
    if abort_on_timeout:
        abort_res = ctx.run(
            [
                "curl", "-s", "-X", "GET",
                "-H", "X-Rundeck-Auth-Token: " + api_token,
                url + "api/" + str(api_version) + "/execution/" + str(exec_id) + "/abort"
            ],
            mutates=True
        )
        if abort_res.rc != 0:
            fail("Failed to abort job: " + abort_res.stderr)

        # Poll until aborted status
        abort_due = ctx.now() + 30 * 1000  # 30s for abort
        while ctx.now() < abort_due:
            abort_status_res = ctx.run(
                [
                    "curl", "-s",
                    "-H", "X-Rundeck-Auth-Token: " + api_token,
                    url + "api/" + str(api_version) + "/execution/" + str(exec_id)
                ],
                mutates=False
            )
            if abort_status_res.rc == 0:
                abort_status_out = abort_status_res.stdout.strip()
                abort_status = ""
                abort_status_pos = abort_status_out.find('"status":')
                if abort_status_pos != -1:
                    rest = abort_status_out[abort_status_pos + 9:]
                    end_quote = rest.find('"')
                    if end_quote != -1:
                        abort_status = rest[1:end_quote]

                if abort_status == "aborted":
                    fail("Job execution aborted due the timeout specified",
                         execution_info={"status": "aborted", "id": exec_id})
            ctx.sleep(1)

    fail("Job execution timed out", execution_info=status_response)
