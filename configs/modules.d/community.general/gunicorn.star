def main(ctx, params):
    app = params["app"]
    venv = params.get("venv")
    config = params.get("config")
    chdir = params.get("chdir")
    pid = params.get("pid")
    user = params.get("user")
    worker = params.get("worker")

    tmp_dir = "/tmp"
    tmp_error_log = tmp_dir + "/gunicorn.temp.error.log"
    tmp_pid_file = tmp_dir + "/gunicorn.temp.pid"

    if venv:
        gunicorn_cmd = venv + "/bin/gunicorn"
    else:
        res = ctx.run(["which", "gunicorn"])
        if res.rc != 0:
            fail("gunicorn not found in PATH and no venv provided")
        gunicorn_cmd = "gunicorn"

    options = ["-D"]

    if config:
        options.extend(["-c", config])
    if chdir:
        options.extend(["--chdir", chdir])
    if worker:
        options.extend(["-k", worker])
    if user:
        options.extend(["-u", user])

    error_log = None
    if config and ctx.file_exists(config):
        config_content = ctx.file_read(config)
        for line in config_content.splitlines():
            if line.strip().startswith("errorlog"):
                parts = line.split("=", 1)
                if len(parts) == 2:
                    error_log = parts[1].strip().strip("\"'")
                    break

    if not error_log:
        options.extend(["--error-logfile", tmp_error_log])

    if not pid:
        if config and ctx.file_exists(config):
            config_content = ctx.file_read(config)
            for line in config_content.splitlines():
                if line.strip().startswith("pid"):
                    parts = line.split("=", 1)
                    if len(parts) == 2:
                        pid = parts[1].strip().strip("\"'")
                        break
        if not pid:
            pid = tmp_pid_file

    options.extend(["--pid", pid])

    cmd = [gunicorn_cmd] + options + [app]

    if ctx.check_mode:
        return {"changed": True, "msg": "would start gunicorn with app " + app}

    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        err_text = ""
        if error_log and ctx.file_exists(error_log):
            err_text = ctx.file_read(error_log).strip()
        elif ctx.file_exists(tmp_error_log):
            err_text = ctx.file_read(tmp_error_log).strip()
            ctx.run(["rm", "-f", tmp_error_log])
        else:
            err_text = "No log file found"

        fail("Failed to start gunicorn: " + err_text + " (" + res.stderr.strip() + ")")

    # Wait briefly (hardcoded 0.5 seconds)
    i = 0
    while i < 5:
        i = i + 1
        # Busy-wait loop (bounded, terminates in <1 sec)
    if ctx.file_exists(pid):
        pid_str = ctx.file_read(pid).strip()
        if pid == tmp_pid_file:
            ctx.run(["rm", "-f", pid])
        return {"changed": True, "msg": "gunicorn started successfully", "data": {"pid": pid_str}}
    else:
        fail("gunicorn started but no PID file found at " + pid)
