def main(ctx, params):
    host = params["host"]
    port = params.get("port", 4646)
    state = params["state"]
    use_ssl = params.get("use_ssl", True)
    timeout = params.get("timeout", 5)
    validate_certs = params.get("validate_certs", True)
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    namespace = params.get("namespace")
    name = params.get("name")
    content = params.get("content")
    content_format = params.get("content_format", "hcl")
    force_start = params.get("force_start", False)
    token = params.get("token")

    # Validation: exactly one of name or content
    if name != None and content != None:
        fail("only one of 'name' or 'content' must be specified")
    if name == None and content == None:
        fail("either 'name' or 'content' must be specified")

    # Build auth header if token provided
    headers = ["-H", "Content-Type: application/json"]
    if token != None:
        headers += ["-H", "X-Nomad-Token: " + token]

    # TLS options
    tls_opts = []
    if not validate_certs:
        tls_opts = ["-k"]
    if client_cert != None and client_key != None:
        tls_opts = ["--cert", client_cert, "--key", client_key]

    # Namespace header (if present)
    ns_opts = []
    if namespace != None:
        ns_opts = ["-H", "X-Nomad-Namespace: " + namespace]

    changed = False
    result = {}

    if state == "present":
        if name != None and not force_start:
            fail("For start job with name, force_start is needed")

        if content != None:
            job_json = content

            if content_format == "hcl":
                # Use nomad job parse to convert HCL to JSON
                res = ctx.run(["nomad", "job", "parse", "-json"] + tls_opts + headers + ns_opts + ["-"], mutates=False, input=content)
                if res.rc != 0:
                    fail("HCL parsing failed: " + res.stderr)
                job_json = res.stdout
            else:
                # Basic JSON validation
                stripped = job_json.strip()
                if stripped == "" or stripped[0] != '{':
                    fail("Invalid JSON content")

            # Extract ID from JSON text
            job_id = ""
            id_pos = job_json.find('"ID"')
            if id_pos != -1:
                after_id = job_json[id_pos + 4:]
                colon_pos = after_id.find(':')
                if colon_pos != -1:
                    val_start = after_id[colon_pos + 1:].strip()
                    if val_start.startswith('"'):
                        end_quote = val_start.find('"', 1)
                        if end_quote != -1:
                            job_id = val_start[1:end_quote]

            if job_id == "":
                fail("Cannot retrieve job ID from content")

            # Plan the job
            plan_cmd = ["nomad", "job", "plan", "-json", job_id]
            plan_res = ctx.run(plan_cmd + tls_opts + headers + ns_opts + ["-"], mutates=False, input=job_json)
            if plan_res.rc != 0:
                # Fall back to validate if plan fails
                validate_cmd = ["nomad", "job", "validate"]
                val_res = ctx.run(validate_cmd + tls_opts + headers + ns_opts + ["-"], mutates=False, input=job_json)
                if val_res.rc != 0:
                    fail("Job plan/validate failed: " + val_res.stderr)
                changed = True
            else:
                plan_out = plan_res.stdout
                if plan_out.find('"Type":"No Change"') == -1 and plan_out.find('"Type": "No Change"') == -1:
                    changed = True

            if changed and not ctx.check_mode:
                reg_res = ctx.run(["nomad", "job", "register", job_id] + tls_opts + headers + ns_opts + ["-"], mutates=True, input=job_json)
                if reg_res.rc != 0:
                    fail("Job registration failed: " + reg_res.stderr)
                result = {"id": job_id}
            elif ctx.check_mode:
                result = {"id": job_id, "planned": True}
            else:
                result = {"id": job_id, "unchanged": True}

        if force_start:
            job_name = name if name != None else None
            if job_name == None:
                # Extract name from content JSON
                name_pos = content.find('"Name"')
                if name_pos != -1:
                    after_name = content[name_pos + 6:]
                    colon_pos = after_name.find(':')
                    if colon_pos != -1:
                        val_start = after_name[colon_pos + 1:].strip()
                        if val_start.startswith('"'):
                            end_quote = val_start.find('"', 1)
                            if end_quote != -1:
                                job_name = val_start[1:end_quote]
                if job_name == None:
                    fail("Unable to determine job name for force_start")

            # Check job status
            get_res = ctx.run(["nomad", "job", "status", "-json", job_name] + tls_opts + headers + ns_opts, mutates=False)
            if get_res.rc != 0:
                fail("Failed to retrieve job status: " + get_res.stderr)

            status = get_res.stdout
            is_running = status.find('"Status":"running"') != -1 or status.find('"Status": "running"') != -1

            if is_running:
                result = {"id": job_name, "status": "running", "unchanged": True}
            else:
                changed = True
                if not ctx.check_mode:
                    reg_res = ctx.run(["nomad", "job", "register", job_name] + tls_opts + headers + ns_opts + ["-"], mutates=True, input=content)
                    if reg_res.rc != 0:
                        fail("Failed to force-start job: " + reg_res.stderr)
                    result = {"id": job_name, "status": "running", "changed": True}
                else:
                    result = {"id": job_name, "status": "would-start", "changed": True}

    if state == "absent":
        if name == None:
            if content_format == "json":
                name_pos = content.find('"Name"')
                if name_pos != -1:
                    after_name = content[name_pos + 6:]
                    colon_pos = after_name.find(':')
                    if colon_pos != -1:
                        val_start = after_name[colon_pos + 1:].strip()
                        if val_start.startswith('"'):
                            end_quote = val_start.find('"', 1)
                            if end_quote != -1:
                                name = val_start[1:end_quote]
            else:
                fail("Cannot extract job name from HCL content in absent state; use 'name'")
        if name == None:
            fail("Job name required for absent state")

        get_res = ctx.run(["nomad", "job", "status", "-json", name] + tls_opts + headers + ns_opts, mutates=False)
        if get_res.rc != 0:
            if get_res.stderr.find("Job not found") != -1 or get_res.stderr.find("job not found") != -1:
                result = {"id": name, "status": "not-found"}
                changed = False
            else:
                fail("Failed to retrieve job: " + get_res.stderr)
        else:
            status = get_res.stdout
            is_dead = status.find('"Status":"dead"') != -1 or status.find('"Status": "dead"') != -1
            if is_dead:
                result = {"id": name, "status": "dead"}
                changed = False
            else:
                changed = True
                if not ctx.check_mode:
                    dereg_res = ctx.run(["nomad", "job", "deregister", name] + tls_opts + headers + ns_opts, mutates=True)
                    if dereg_res.rc != 0:
                        fail("Failed to deregister job: " + dereg_res.stderr)
                    result = {"id": name, "status": "deregistered"}
                else:
                    result = {"id": name, "status": "would-deregister"}

    msg = "Job operation completed"
    if not changed:
        msg = "Job already in desired state"
    elif ctx.check_mode:
        msg = "would perform job operation"

    return {"changed": changed, "msg": msg, "result": result}
