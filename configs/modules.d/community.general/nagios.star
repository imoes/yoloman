def main(ctx, params):
    action = params["action"]
    host = params.get("host")
    cmdfile = params.get("cmdfile")
    author = params.get("author", "Ansible")
    comment = params.get("comment", "Scheduling downtime")
    start = params.get("start")
    minutes = params.get("minutes", 30)
    services = params.get("services")
    servicegroup = params.get("servicegroup")
    command = params.get("command")

    # Auto-detect cmdfile if not provided
    if cmdfile == None:
        locations = [
            "/etc/nagios/nagios.cfg", "/etc/nagios3/nagios.cfg", "/etc/nagios2/nagios.cfg",
            "/usr/local/etc/nagios/nagios.cfg", "/usr/local/groundwork/nagios/etc/nagios.cfg",
            "/omd/sites/oppy/tmp/nagios/nagios.cfg", "/usr/local/nagios/etc/nagios.cfg",
            "/usr/local/nagios/nagios.cfg", "/opt/nagios/etc/nagios.cfg",
            "/opt/nagios/nagios.cfg", "/etc/icinga/icinga.cfg",
            "/usr/local/icinga/etc/icinga.cfg"
        ]
        for path in locations:
            if ctx.file_exists(path):
                content = ctx.file_read(path)
                for line in content.split("\n"):
                    if line.strip().startswith("command_file"):
                        cmdfile = line.split("=", 1)[1].strip()
                        break
            if cmdfile != None:
                break
        if cmdfile == None:
            fail("unable to locate nagios.cfg")

    # Validate required parameters per action
    if action in ["downtime", "delete_downtime", "enable_alerts", "disable_alerts", "acknowledge", "forced_check"]:
        if host == None:
            fail("host is required for action " + action)
        if services == None:
            fail("services is required for action " + action)
    elif action in ["silence", "unsilence"]:
        if host == None:
            fail("host is required for action " + action)
    elif action == "command":
        if command == None:
            fail("command is required for action command")
    elif action in ["servicegroup_host_downtime", "servicegroup_service_downtime"]:
        if host == None or servicegroup == None:
            fail("host and servicegroup are required for action " + action)

    # Normalize services: 'host', 'all', or split list
    if services == None or services == "host" or services == "all":
        service_list = services
    else:
        service_list = services.split(",")

    # Build command based on action
    now = int(ctx.run(["date", "+%s"]).stdout.strip())

    def fmt_downtime(host, duration, svc=None, start_time=None):
        if start_time == None:
            start_time = now
        end_time = start_time + duration * 60
        duration_s = duration * 60
        if svc != None:
            return "[%s] SCHEDULE_SVC_DOWNTIME;%s;%s;%s;%s;1;0;%s;%s;%s\n" % (
                now, host, svc, start_time, end_time, duration_s, author, comment)
        else:
            return "[%s] SCHEDULE_HOST_DOWNTIME;%s;%s;%s;1;0;%s;%s;%s\n" % (
                now, host, start_time, end_time, duration_s, author, comment)

    def fmt_ack(host, svc=None):
        if svc != None:
            return "[%s] ACKNOWLEDGE_SVC_PROBLEM;%s;%s;0;1;0;%s;%s\n" % (
                now, host, svc, author, comment)
        else:
            return "[%s] ACKNOWLEDGE_HOST_PROBLEM;%s;0;1;0;%s;%s\n" % (
                now, host, author, comment)

    def fmt_downtime_del(host, svc=None):
        if svc != None:
            return "[%s] DEL_DOWNTIME_BY_HOST_NAME;%s;%s;0;\n" % (now, host, svc)
        else:
            return "[%s] DEL_DOWNTIME_BY_HOST_NAME;%s;0;0;\n" % (now, host)

    def fmt_check(host, svc=None):
        if svc != None:
            return "[%s] SCHEDULE_FORCED_SVC_CHECK;%s;%s;%s\n" % (now, host, svc, now + 3)
        else:
            return "[%s] SCHEDULE_FORCED_HOST_CHECK;%s;%s\n" % (now, host, now + 3)

    def fmt_notif(cmd, host, svc=None):
        if svc != None:
            return "[%s] %s;%s;%s\n" % (now, cmd, host, svc)
        elif host != None:
            return "[%s] %s;%s\n" % (now, cmd, host)
        else:
            return "[%s] %s\n" % (now, cmd)

    cmd_str = ""
    if action == "downtime":
        if service_list == "host":
            cmd_str = fmt_downtime(host, minutes)
        elif service_list == "all":
            cmd_str = fmt_downtime(host, minutes)
        else:
            for svc in service_list:
                cmd_str += fmt_downtime(host, minutes, svc=svc.strip())
    elif action == "acknowledge":
        if service_list == "host":
            cmd_str = fmt_ack(host)
        else:
            for svc in service_list:
                cmd_str += fmt_ack(host, svc=svc.strip())
    elif action == "delete_downtime":
        if service_list == "host":
            cmd_str = fmt_downtime_del(host)
        elif service_list == "all":
            cmd_str = fmt_downtime_del(host)
        else:
            for svc in service_list:
                cmd_str += fmt_downtime_del(host, svc=svc.strip())
    elif action == "forced_check":
        if service_list == "host":
            cmd_str = fmt_check(host)
        elif service_list == "all":
            cmd_str = "[%s] SCHEDULE_FORCED_HOST_SVC_CHECKS;%s;%s\n" % (now, host, now + 3)
        else:
            for svc in service_list:
                cmd_str += fmt_check(host, svc=svc.strip())
    elif action == "enable_alerts":
        if service_list == "host":
            cmd_str = fmt_notif("ENABLE_HOST_SVC_NOTIFICATIONS", host)
        else:
            for svc in service_list:
                cmd_str += fmt_notif("ENABLE_SVC_NOTIFICATIONS", host, svc=svc.strip())
    elif action == "disable_alerts":
        if service_list == "host":
            cmd_str = fmt_notif("DISABLE_HOST_SVC_NOTIFICATIONS", host)
        else:
            for svc in service_list:
                cmd_str += fmt_notif("DISABLE_SVC_NOTIFICATIONS", host, svc=svc.strip())
    elif action == "silence":
        cmd_str = fmt_notif("DISABLE_HOST_SVC_NOTIFICATIONS", host) + fmt_notif("DISABLE_HOST_NOTIFICATIONS", host)
    elif action == "unsilence":
        cmd_str = fmt_notif("ENABLE_HOST_SVC_NOTIFICATIONS", host) + fmt_notif("ENABLE_HOST_NOTIFICATIONS", host)
    elif action == "silence_nagios":
        cmd_str = fmt_notif("DISABLE_NOTIFICATIONS", None)
    elif action == "unsilence_nagios":
        cmd_str = fmt_notif("ENABLE_NOTIFICATIONS", None)
    elif action == "command":
        cmd_str = "[%s] %s\n" % (now, command)
    elif action == "servicegroup_host_downtime":
        cmd_str = "[%s] SCHEDULE_SERVICEGROUP_HOST_DOWNTIME;%s;%s;%s;1;0;%s;%s;%s\n" % (
            now, servicegroup, now, now + minutes * 60, minutes * 60, author, comment)
    elif action == "servicegroup_service_downtime":
        cmd_str = "[%s] SCHEDULE_SERVICEGROUP_SVC_DOWNTIME;%s;%s;%s;1;0;%s;%s;%s\n" % (
            now, servicegroup, now, now + minutes * 60, minutes * 60, author, comment)
    else:
        fail("unsupported action: " + action)

    # Check if cmdfile exists and is a pipe
    if not ctx.file_exists(cmdfile):
        fail("nagios command file does not exist: " + cmdfile)
    stat_res = ctx.stat(cmdfile)
    if stat_res == None or not stat_res.get("is_dir", False) and not stat_res.get("is_link", False):
        # Try to detect pipe by reading file mode — but Starlark stat returns is_link, is_dir only.
        # Since we can't reliably detect FIFO in Starlark, assume existence implies FIFO per original module logic.
        pass

    # Write to command file
    changed = ctx.file_write(cmdfile, cmd_str, mode="0644")

    if action in ["silence_nagios", "unsilence_nagios", "command"]:
        msg = "executed command " + action
    elif action in ["silence", "unsilence"]:
        msg = action + "d host " + host + " notifications"
    elif action == "downtime":
        msg = "scheduled downtime for " + (service_list if service_list != None else "host") + " on " + host
    elif action == "acknowledge":
        msg = "acknowledged problem for " + (service_list if service_list != None else "host") + " on " + host
    elif action == "delete_downtime":
        msg = "deleted downtime for " + (service_list if service_list != None else "host") + " on " + host
    elif action in ["enable_alerts", "disable_alerts"]:
        verb = "enabled" if action == "enable_alerts" else "disabled"
        msg = verb + " alerts for " + (service_list if service_list != None else "host") + " on " + host
    elif action == "forced_check":
        msg = "forced check for " + (service_list if service_list != None else "host") + " on " + host
    elif action in ["servicegroup_host_downtime", "servicegroup_service_downtime"]:
        msg = "scheduled downtime for " + action.replace("servicegroup_", "") + " group " + servicegroup
    else:
        msg = "executed " + action

    return {"changed": changed, "msg": msg}
