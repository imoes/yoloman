def main(ctx, params):
    name = params["name"]
    state = params["state"]
    timeout = params.get("timeout", 300)

    monit_bin = "monit"
    state_command_map = {
        "stopped": "stop",
        "started": "start",
        "monitored": "monitor",
        "unmonitored": "unmonitor",
        "restarted": "restart"
    }

    def get_monit_version():
        res = ctx.run([monit_bin, "-V"], mutates=False)
        if res.rc != 0:
            fail("Failed to get monit version: " + res.stderr)
        lines = res.stdout.split("\n")
        version_line = lines[0] if lines else ""
        idx = version_line.find(" version ")
        if idx >= 0:
            version_str = version_line[idx + 9:]
            parts = version_str.split()[-1].split(".")
            if len(parts) < 2:
                parts = ["0", "0"]
            major = int(parts[0])
            minor = int(parts[1])
            return (major, minor)
        return (0, 0)

    monit_version = get_monit_version()
    use_B_flag = monit_version > (5, 18)
    cmd_args = ["-B"] if use_B_flag else []

    def get_status(validate=False):
        monit_command = "validate" if validate else "status"
        ok_codes = [0, 1] if validate else [0]
        res = ctx.run([monit_bin, monit_command] + cmd_args + [name], mutates=False, ok_codes=ok_codes)
        return parse_status(res.stdout, res.stderr)

    def parse_status(output, err):
        services = ["Process", "File", "Fifo", "Filesystem", "Directory", "Remote host", "System", "Program"]
        found = False
        for line in output.split("\n"):
            for svc in services:
                if svc in line and name in line:
                    found = True
                    break
            if found:
                break
        if not found:
            return "missing"

        status_vals = []
        for line in output.split("\n"):
            stripped = line.strip()
            if stripped.lower().startswith("status"):
                status_vals.append(stripped[6:].strip())

        if not status_vals:
            fail("Unable to find process status in monit output")

        status_val = status_vals[0].upper()
        if " | " in status_val:
            status_val = status_val.split(" | ")[0].strip()
        if " - " not in status_val:
            status_val = status_val.replace(" ", "_")
            if status_val == "OK":
                return "ok"
            if status_val == "NOT_MONITORED":
                return "not_monitored"
            if status_val == "INITIALIZING":
                return "initializing"
            if status_val == "DOES_NOT_EXIST":
                return "does_not_exist"
            if status_val == "EXECUTION_FAILED":
                return "execution_failed"
            return "ok"
        else:
            parts = status_val.split(" - ")
            substatus = parts[1] if len(parts) > 1 else ""
            if "START" in substatus or "INITIALIZING" in substatus or "RESTART" in substatus or "MONITOR" in substatus:
                status = "ok"
            else:
                status = "not_monitored"
            if "pending" in substatus.lower():
                status = status + "_pending"
            return status

    def is_process_present():
        res = ctx.run([monit_bin, "summary"] + cmd_args, mutates=False)
        if res.rc != 0:
            return False
        for line in res.stdout.split("\n"):
            tokens = line.strip().split()
            if len(tokens) > 0 and tokens[0] == name:
                return True
        return False

    def is_process_running():
        status = get_status()
        return status == "ok"

    def wait_for_status_change(current_status, max_retries=6):
        retries = 0
        while retries < max_retries:
            new_status = get_status()
            if new_status != current_status or current_status == "execution_failed":
                return new_status
            retries += 1
            if retries < max_retries:
                ctx.run(["sleep", "0.5"], mutates=False)
                validate = retries % 2 == 0
                new_status = get_status(validate=validate)
                if new_status != current_status:
                    return new_status
        return current_status

    def wait_for_monit_to_stop_pending(current_status=None, max_wait=timeout):
        if current_status == None:
            current_status = get_status()
        waiting_statuses = ["missing", "initializing", "does_not_exist"]
        elapsed = 0
        while current_status.endswith("_pending") or current_status in waiting_statuses:
            if elapsed >= max_wait:
                fail("waited too long for pending/initiating status to go away")
            ctx.run(["sleep", "5"], mutates=False)
            elapsed += 5
            current_status = get_status(validate=True)
        return current_status

    if state == "reloaded":
        res = ctx.run([monit_bin, "reload"], mutates=True)
        if res.rc != 0:
            fail("monit reload failed: " + res.stderr)
        return {"changed": True, "msg": "monit reloaded"}

    present = is_process_present()

    if not present and state != "present":
        fail(name + " process not presently configured with monit")

    if state == "present":
        if present:
            return {"changed": False, "msg": name + " already present"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would wait for process to become present"}
        elapsed = 0
        while not present:
            if elapsed >= timeout:
                fail("waited too long for process to become 'present'")
            ctx.run(["sleep", "5"], mutates=False)
            elapsed += 5
            present = is_process_present()
        return {"changed": True, "msg": name + " is now present"}

    wait_for_monit_to_stop_pending()

    running = is_process_running()

    if state in ["started", "monitored"]:
        if running:
            return {"changed": False, "msg": name + " already " + state}
        if ctx.check_mode:
            return {"changed": True, "msg": "would " + state + " process"}
        cmd = state_command_map[state]
        res = ctx.run([monit_bin, cmd, name], mutates=True)
        if res.rc != 0:
            fail(name + " failed to " + state + ": " + res.stderr)
        current_status = get_status()
        new_status = wait_for_status_change(current_status)
        new_status = wait_for_monit_to_stop_pending(new_status)
        expected = "ok" if state == "started" else "not_monitored"
        if new_status == expected:
            return {"changed": True, "msg": name + " " + state + " successfully"}
        fail(name + " process not " + state + " after action")

    if state == "stopped":
        if not running:
            return {"changed": False, "msg": name + " already stopped"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would stop process"}
        res = ctx.run([monit_bin, "stop", name], mutates=True)
        if res.rc != 0:
            fail(name + " failed to stop: " + res.stderr)
        current_status = get_status()
        new_status = wait_for_status_change(current_status)
        new_status = wait_for_monit_to_stop_pending(new_status)
        expected = "not_monitored"
        if new_status == expected:
            return {"changed": True, "msg": name + " stopped successfully"}
        fail(name + " process not stopped after action")

    if state == "unmonitored":
        if not running:
            return {"changed": False, "msg": name + " already unmonitored (not running)"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would unmonitor process"}
        res = ctx.run([monit_bin, "unmonitor", name], mutates=True)
        if res.rc != 0:
            fail(name + " failed to unmonitor: " + res.stderr)
        current_status = get_status()
        new_status = wait_for_status_change(current_status)
        new_status = wait_for_monit_to_stop_pending(new_status)
        expected = "not_monitored"
        if new_status == expected:
            return {"changed": True, "msg": name + " unmonitored successfully"}
        fail(name + " process not unmonitored after action")

    if state == "restarted":
        if not running:
            return {"changed": False, "msg": name + " not running; cannot restart"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would restart process"}
        res = ctx.run([monit_bin, "restart", name], mutates=True)
        if res.rc != 0:
            fail(name + " failed to restart: " + res.stderr)
        current_status = get_status()
        new_status = wait_for_status_change(current_status)
        new_status = wait_for_monit_to_stop_pending(new_status)
        expected = "ok"
        if new_status == expected:
            return {"changed": True, "msg": name + " restarted successfully"}
        fail(name + " process not restarted after action")

    fail("unsupported state: " + state)
