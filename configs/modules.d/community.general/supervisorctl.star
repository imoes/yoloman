def main(ctx, params):
    name = params["name"]
    state = params["state"]
    stop_before_removing = params.get("stop_before_removing", False)
    config = params.get("config")
    server_url = params.get("server_url")
    username = params.get("username")
    password = params.get("password")
    supervisorctl_path = params.get("supervisorctl_path")
    signal = params.get("signal")

    # Validate state=signalled requires signal
    if state == "signalled" and signal == None:
        fail("signal is required when state is signalled")

    # Determine if name ends with ':' indicating a group
    is_group = name.endswith(":")
    if is_group:
        name = name.rstrip(":")

    # Build supervisorctl command path
    if supervisorctl_path != None:
        supervisorctl_args = [supervisorctl_path]
    else:
        supervisorctl_args = ["supervisorctl"]

    # Build base args list
    args_base = list(supervisorctl_args)
    if config != None:
        args_base.extend(["-c", config])
    if server_url != None:
        args_base.extend(["-s", server_url])
    if username != None:
        args_base.extend(["-u", username])
    if password != None:
        args_base.extend(["-p", password])

    def run_supervisorctl(cmd, name_arg=None, ok_codes=[0]):
        cmd_args = list(args_base)
        cmd_args.append(cmd)
        if name_arg != None:
            cmd_args.append(name_arg)
        return ctx.run(cmd_args, mutates=False, ok_codes=ok_codes)

    def get_matched_processes():
        res = run_supervisorctl("status")
        if res.rc != 0:
            return []
        matched = []
        for line in res.stdout.splitlines():
            fields = [f for f in line.split(" ") if f != ""]
            if len(fields) < 2:
                continue
            process_name = fields[0]
            status = fields[1]

            if is_group:
                # Only consider processes in the group (name:process)
                if ":" in process_name:
                    group = process_name.split(":")[0]
                    if group == name:
                        matched.append((process_name, status))
            else:
                # Match exact name or "all"
                if process_name == name or name == "all":
                    matched.append((process_name, status))
        return matched

    if state == "restarted":
        res_update = ctx.run(args_base + ["update"], mutates=True, ok_codes=[0, 2])
        if res_update.rc != 0 and res_update.rc != 2:
            fail("supervisorctl update failed: " + res_update.stderr)
        processes = get_matched_processes()
        if len(processes) == 0:
            fail("ERROR (no such process)")
        changed = False
        for proc_name, _ in processes:
            if ctx.check_mode:
                changed = True
                continue
            res_restart = ctx.run(args_base + ["restart", proc_name], mutates=True, ok_codes=[0, 2])
            if res_restart.rc != 0 and res_restart.rc != 2:
                fail("restart failed for " + proc_name + ": " + res_restart.stderr)
            changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "would restart " + name}
        if changed:
            return {"changed": True, "msg": "restarted " + name}
        return {"changed": False, "msg": name + " already restarted"}

    processes = get_matched_processes()

    if state == "absent":
        if len(processes) == 0:
            return {"changed": False, "msg": name + " not present"}

        if stop_before_removing:
            for proc_name, status in processes:
                if status in ("RUNNING", "STARTING"):
                    if ctx.check_mode:
                        continue
                    res_stop = ctx.run(args_base + ["stop", proc_name], mutates=True, ok_codes=[0, 2])
                    if res_stop.rc != 0 and res_stop.rc != 2:
                        fail("failed to stop " + proc_name + ": " + res_stop.stderr)

        if ctx.check_mode:
            return {"changed": True, "msg": "would remove " + name}
        # In real mode: reread then remove
        res_reread = ctx.run(args_base + ["reread"], mutates=True, ok_codes=[0])
        if res_reread.rc != 0:
            fail("reread failed: " + res_reread.stderr)
        res_remove = ctx.run(args_base + ["remove", name], mutates=True, ok_codes=[0])
        if res_remove.rc != 0:
            fail("remove failed: " + res_remove.stderr)
        return {"changed": True, "msg": name + " removed"}

    if state == "present":
        if len(processes) > 0:
            return {"changed": False, "msg": name + " already present"}

        if ctx.check_mode:
            return {"changed": True, "msg": "would add " + name}
        # In real mode: reread then add
        res_reread = ctx.run(args_base + ["reread"], mutates=True, ok_codes=[0])
        if res_reread.rc != 0:
            fail("reread failed: " + res_reread.stderr)
        res_add = ctx.run(args_base + ["add", name], mutates=True, ok_codes=[0])
        if res_add.rc != 0:
            fail("add failed: " + res_add.stderr)
        return {"changed": True, "msg": name + " added"}

    # From here, require at least one matched process
    if len(processes) == 0:
        fail("ERROR (no such process)")

    if state == "started":
        changed = False
        for proc_name, status in processes:
            if status not in ("RUNNING", "STARTING"):
                if ctx.check_mode:
                    changed = True
                    continue
                res_start = ctx.run(args_base + ["start", proc_name], mutates=True, ok_codes=[0, 2])
                if res_start.rc != 0 and res_start.rc != 2:
                    fail("failed to start " + proc_name + ": " + res_start.stderr)
                changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "would start " + name}
        if changed:
            return {"changed": True, "msg": "started " + name}
        return {"changed": False, "msg": name + " already started"}

    if state == "stopped":
        changed = False
        for proc_name, status in processes:
            if status in ("RUNNING", "STARTING"):
                if ctx.check_mode:
                    changed = True
                    continue
                res_stop = ctx.run(args_base + ["stop", proc_name], mutates=True, ok_codes=[0, 2])
                if res_stop.rc != 0 and res_stop.rc != 2:
                    fail("failed to stop " + proc_name + ": " + res_stop.stderr)
                changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "would stop " + name}
        if changed:
            return {"changed": True, "msg": "stopped " + name}
        return {"changed": False, "msg": name + " already stopped"}

    if state == "signalled":
        changed = False
        for proc_name, status in processes:
            if status == "RUNNING":
                if ctx.check_mode:
                    changed = True
                    continue
                res_signal = ctx.run(args_base + ["signal", signal, proc_name], mutates=True, ok_codes=[0])
                if res_signal.rc != 0:
                    fail("failed to signal " + proc_name + ": " + res_signal.stderr)
                changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "would signal " + name}
        if changed:
            return {"changed": True, "msg": "signalled " + name}
        return {"changed": False, "msg": name + " already signalled"}

    fail("unsupported state: " + state)
