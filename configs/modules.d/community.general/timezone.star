def main(ctx, params):
    name = params.get("name")
    hwclock = params.get("hwclock")

    if name == None and hwclock == None:
        fail("At least one of name and hwclock are required")

    os_family = ctx.facts().get("os_family", "")
    hostname = ctx.facts().get("hostname", "")
    distribution = ctx.facts().get("distribution", "")

    # Determine platform-specific handler
    if os_family == "Linux":
        # Check if timedatectl is available and works
        res = ctx.run(["timedatectl", "status"], mutates=False)
        if res.rc == 0:
            return _handle_systemd(ctx, name, hwclock)
        else:
            return _handle_nosystemd_linux(ctx, name, hwclock, distribution)
    elif os_family == "SunOS":
        # SmartOS detection
        if hostname.startswith("joyent_") and hostname.endswith("Z"):
            return _handle_smartos(ctx, name, hwclock)
        else:
            fail("timezone module is not supported on this SunOS system")
    elif os_family == "Darwin":
        return _handle_darwin(ctx, name, hwclock)
    elif os_family in ("FreeBSD", "NetBSD", "OpenBSD"):
        return _handle_bsd(ctx, name, hwclock)
    elif os_family == "AIX":
        return _handle_aix(ctx, name, hwclock)
    else:
        fail("timezone module is not supported on this platform")

def _handle_systemd(ctx, name, hwclock):
    # Get current status
    res = ctx.run(["timedatectl", "status"], mutates=False)
    status = res.stdout
    lines = status.split("\n")
    tz_current = ""
    hw_current = ""
    for line in lines:
        if line.find("Time zone:") != -1:
            parts = line.split()
            if len(parts) >= 3:
                tz_current = parts[2]
        elif line.find("RTC in local TZ") != -1:
            val = line.split(":")[-1].strip().lower()
            if val == "yes":
                hw_current = "local"
            elif val == "no":
                hw_current = "UTC"
            else:
                hw_current = "n/a"

    # Determine desired state
    tz_desired = name if name != None else tz_current
    hw_desired = hwclock if hwclock != None else hw_current

    if tz_current == tz_desired and hw_current == hw_desired:
        return {"changed": False, "msg": "timezone already set correctly"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would update timezone settings"}

    # Apply changes
    if name != None and tz_current != tz_desired:
        # Validate timezone exists
        tzfile = "/usr/share/zoneinfo/" + tz_desired
        if not ctx.file_exists(tzfile):
            fail("given timezone %s is not available" % tz_desired)
        res = ctx.run(["timedatectl", "set-timezone", tz_desired], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would set timezone to " + tz_desired}
        if res.rc != 0:
            fail("failed to set timezone: " + res.stderr)

    if hwclock != None and hw_current != hw_desired:
        val = "yes" if hw_desired == "local" else "no"
        res = ctx.run(["timedatectl", "set-local-rtc", val], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would set hardware clock to " + hw_desired}
        if res.rc != 0:
            fail("failed to set hardware clock: " + res.stderr)

    return {"changed": True, "msg": "timezone updated"}

def _handle_nosystemd_linux(ctx, name, hwclock, distribution):
    # Get current timezone from /etc/localtime (symlink or file)
    tz_current = _get_current_timezone_nosystemd(ctx)

    # Get current hwclock setting
    hw_current = _get_hwclock_nosystemd(ctx, distribution)

    tz_desired = name if name != None else tz_current
    hw_desired = hwclock if hwclock != None else hw_current

    if tz_current == tz_desired and hw_current == hw_desired:
        return {"changed": False, "msg": "timezone already set correctly"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would update timezone settings"}

    # Apply timezone change
    if name != None and tz_current != tz_desired:
        tzfile = "/usr/share/zoneinfo/" + tz_desired
        if not ctx.file_exists(tzfile):
            fail("given timezone %s is not available" % tz_desired)

        if distribution in ("Ubuntu", "Debian"):
            ctx.run(["ln", "-sf", tzfile, "/etc/localtime"], mutates=True)
            ctx.run(["dpkg-reconfigure", "--frontend", "noninteractive", "tzdata"], mutates=True)
        elif distribution in ("RedHat", "CentOS", "Fedora"):
            ctx.run(["cp", "--remove-destination", tzfile, "/etc/localtime"], mutates=True)
            tzdata_update = ctx.run(["which", "tzdata-update"], mutates=False)
            if tzdata_update.rc == 0:
                ctx.run(["tzdata-update"], mutates=True)
        elif distribution == "SuSE":
            ctx.run(["cp", "--remove-destination", tzfile, "/etc/localtime"], mutates=True)
        elif distribution == "Alpine":
            ctx.run(["setup-timezone", "-z", tz_desired], mutates=True)
        elif distribution == "Gentoo":
            # No specific command for Gentoo in original code; fallback to copy
            ctx.run(["cp", "--remove-destination", tzfile, "/etc/localtime"], mutates=True)
        else:
            ctx.run(["cp", "--remove-destination", tzfile, "/etc/localtime"], mutates=True)

        # Update /etc/timezone or /etc/sysconfig/clock as needed
        _update_tz_config_nosystemd(ctx, tz_desired, distribution)

    # Apply hwclock change
    if hwclock != None and hw_current != hw_desired:
        option = "--localtime" if hw_desired == "local" else "--utc"
        ctx.run(["hwclock", "--systohc", option], mutates=True)

        # Update UTC= setting in config file
        _update_hwclock_config_nosystemd(ctx, hw_desired, distribution)

    return {"changed": True, "msg": "timezone updated"}

def _get_current_timezone_nosystemd(ctx):
    localtime = "/etc/localtime"
    if not ctx.file_exists(localtime):
        return "UTC"

    # Check if it's a symlink
    stat = ctx.stat(localtime)
    if stat == None:
        return "UTC"

    if stat.get("is_link", False):
        # Follow the symlink and extract tz name
        link_path = stat.get("link_target", "")
        if link_path.startswith("/usr/share/zoneinfo/"):
            return link_path[len("/usr/share/zoneinfo/"):]
        if link_path.startswith("/etc/zoneinfo/"):
            return link_path[len("/etc/zoneinfo/"):]
        # Try alternate path patterns
        for prefix in ["/usr/share/zoneinfo/", "/usr/share/lib/zoneinfo/", "/etc/zoneinfo/"]:
            if link_path.startswith(prefix):
                return link_path[len(prefix):]
        return "n/a"
    else:
        # Compare with zoneinfo files
        zoneinfo_dir = "/usr/share/zoneinfo/"
        for tzname in ["UTC", "Etc/UTC"]:
            tzfile = zoneinfo_dir + tzname
            if ctx.file_exists(tzfile):
                # Simple comparison via file read and compare
                current = ctx.file_read(localtime)
                candidate = ctx.file_read(tzfile)
                if current == candidate:
                    return tzname
        return "n/a"

def _get_hwclock_nosystemd(ctx, distribution):
    # Check /etc/adjtime first
    adjtime_path = "/etc/adjtime"
    if ctx.file_exists(adjtime_path):
        content = ctx.file_read(adjtime_path)
        if content.find("LOCAL") != -1:
            return "local"
        elif content.find("UTC") != -1:
            return "UTC"
        # If unknown, default to UTC
        return "UTC"

    # Then check config files
    conf_path = "/etc/sysconfig/clock"
    if ctx.file_exists(conf_path):
        content = ctx.file_read(conf_path)
        if content.find("UTC=yes") != -1 or content.find("UTC = yes") != -1:
            return "UTC"
        elif content.find("UTC=no") != -1 or content.find("UTC = no") != -1:
            return "local"

    conf_path = "/etc/default/rcS"
    if ctx.file_exists(conf_path):
        content = ctx.file_read(conf_path)
        if content.find("UTC=yes") != -1 or content.find("UTC = yes") != -1:
            return "UTC"
        elif content.find("UTC=no") != -1 or content.find("UTC = no") != -1:
            return "local"

    # Default fallback
    return "UTC"

def _update_tz_config_nosystemd(ctx, tz_name, distribution):
    # Update /etc/timezone for Debian/Ubuntu
    if distribution in ("Ubuntu", "Debian"):
        conf_path = "/etc/timezone"
        content = tz_name + "\n"
        if ctx.file_exists(conf_path):
            existing = ctx.file_read(conf_path)
            if existing.strip() == tz_name:
                return
        ctx.file_write(conf_path, content)
        return

    # Update /etc/sysconfig/clock for RHEL/CentOS/SUSE
    conf_path = "/etc/sysconfig/clock"
    if not ctx.file_exists(conf_path):
        # Create with defaults if missing
        if distribution == "SuSE":
            content = 'TIMEZONE="%s"\n' % tz_name + 'UTC=true\n'
        else:
            content = 'ZONE="%s"\n' % tz_name
        ctx.file_write(conf_path, content)
        return

    content = ctx.file_read(conf_path)
    lines = content.split("\n")
    new_lines = []

    # Determine key name based on content
    key = "ZONE"
    for line in lines:
        if line.startswith("TIMEZONE=") or line.startswith("TIMEZONE ="):
            key = "TIMEZONE"
            break

    found = False
    for line in lines:
        if line.startswith(key + "=") or line.startswith(key + " ="):
            if key == "TIMEZONE":
                new_lines.append('TIMEZONE="%s"' % tz_name)
            else:
                new_lines.append('ZONE="%s"' % tz_name)
            found = True
        else:
            new_lines.append(line)

    if not found:
        if key == "TIMEZONE":
            new_lines.append('TIMEZONE="%s"' % tz_name)
        else:
            new_lines.append('ZONE="%s"' % tz_name)

    new_content = "\n".join(new_lines)
    ctx.file_write(conf_path, new_content)

def _update_hwclock_config_nosystemd(ctx, hw_val, distribution):
    # Determine config file path
    conf_path = "/etc/sysconfig/clock"
    if distribution in ("Ubuntu", "Debian"):
        conf_path = "/etc/default/rcS"
    elif distribution == "Alpine":
        conf_path = "/etc/conf.d/hwclock"

    utc_val = "yes" if hw_val == "UTC" else "no"
    line = "UTC=" + utc_val + "\n"

    if ctx.file_exists(conf_path):
        content = ctx.file_read(conf_path)
        lines = content.split("\n")
        new_lines = []
        found = False
        for l in lines:
            if l.strip().startswith("UTC="):
                new_lines.append(line.strip())
                found = True
            else:
                new_lines.append(l)
        if not found:
            new_lines.append(line.strip())
        new_content = "\n".join(new_lines)
        ctx.file_write(conf_path, new_content)
    else:
        ctx.file_write(conf_path, line)

def _handle_smartos(ctx, name, hwclock):
    if hwclock != None:
        fail("hwclock is not supported on SmartOS")

    if name == None:
        fail("name is required on SmartOS")

    # Check current timezone
    content = ""
    if ctx.file_exists("/etc/default/init"):
        content = ctx.file_read("/etc/default/init")
    tz_current = ""
    for line in content.split("\n"):
        if line.startswith("TZ="):
            parts = line.split("=", 1)
            if len(parts) >= 2:
                tz_current = parts[1].strip()
            break

    if tz_current == name:
        return {"changed": False, "msg": "timezone already set correctly"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would set timezone to " + name}

    # Validate timezone
    tzfile = "/usr/share/zoneinfo/" + name
    if not ctx.file_exists(tzfile):
        fail("given timezone %s is not available" % name)

    # Set timezone
    res = ctx.run(["sm-set-timezone", name], mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would set timezone to " + name}
    if res.rc != 0:
        fail("failed to set timezone: " + res.stderr)

    return {"changed": True, "msg": "timezone updated"}

def _handle_darwin(ctx, name, hwclock):
    if hwclock != None:
        fail("hwclock is not supported on Darwin")

    if name == None:
        fail("name is required on Darwin")

    # Check current timezone
    res = ctx.run(["systemsetup", "-gettimezone"], mutates=False)
    current = res.stdout
    tz_current = ""
    for line in current.split("\n"):
        if line.find("Time Zone:") != -1:
            parts = line.split()
            if len(parts) >= 3:
                tz_current = parts[2]

    if tz_current == name:
        return {"changed": False, "msg": "timezone already set correctly"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would set timezone to " + name}

    # Validate timezone exists
    res = ctx.run(["systemsetup", "-listtimezones"], mutates=False)
    available = res.stdout
    tz_list = []
    skip = True
    for line in available.split("\n"):
        if skip:
            skip = False
            continue
        tz = line.strip()
        if tz:
            tz_list.append(tz)

    if name not in tz_list:
        fail("given timezone %s is not available" % name)

    # Set timezone
    res = ctx.run(["systemsetup", "-settimezone", name], mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would set timezone to " + name}
    if res.rc != 0:
        fail("failed to set timezone: " + res.stderr)

    return {"changed": True, "msg": "timezone updated"}

def _handle_bsd(ctx, name, hwclock):
    if hwclock != None:
        fail("hwclock is not supported on BSD")

    if name == None:
        fail("name is required on BSD")

    # Get current timezone
    tz_current = _get_current_timezone_bsd(ctx)

    if tz_current == name:
        return {"changed": False, "msg": "timezone already set correctly"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would set timezone to " + name}

    # Validate timezone
    tzfile = "/usr/share/zoneinfo/" + name
    if not ctx.file_exists(tzfile):
        fail("given timezone %s is not available" % name)

    # Set timezone (atomically via symlink)
    # In check_mode, ctx.file_write handles everything
    if not ctx.check_mode:
        localtime = "/etc/localtime"
        ctx.run(["ln", "-sf", tzfile, localtime], mutates=True)
    else:
        # Simulate by checking symlink state
        pass

    return {"changed": True, "msg": "timezone updated"}

def _get_current_timezone_bsd(ctx):
    localtime = "/etc/localtime"
    if not ctx.file_exists(localtime):
        return "UTC"

    stat = ctx.stat(localtime)
    if stat == None:
        return "UTC"

    if stat.get("is_link", False):
        link_path = stat.get("link_target", "")
        for prefix in ["/usr/share/zoneinfo/", "/usr/share/lib/zoneinfo/"]:
            if link_path.startswith(prefix):
                return link_path[len(prefix):]
        return "UTC"
    else:
        # Compare with zoneinfo files (fallback)
        for tz in ["UTC", "Etc/UTC"]:
            tzfile = "/usr/share/zoneinfo/" + tz
            if ctx.file_exists(tzfile):
                current = ctx.file_read(localtime)
                candidate = ctx.file_read(tzfile)
                if current == candidate:
                    return tz
        return "UTC"

def _handle_aix(ctx, name, hwclock):
    if hwclock != None:
        fail("hwclock is not supported on AIX")

    if name == None:
        fail("name is required on AIX")

    # Get current timezone
    content = ""
    if ctx.file_exists("/etc/environment"):
        content = ctx.file_read("/etc/environment")
    tz_current = ""
    for line in content.split("\n"):
        if line.startswith("TZ="):
            parts = line.split("=", 1)
            if len(parts) >= 2:
                tz_current = parts[1].strip()
            break

    if tz_current == name:
        return {"changed": False, "msg": "timezone already set correctly"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would set timezone to " + name}

    # Validate timezone
    tzfile = "/usr/share/lib/zoneinfo/" + name
    if not ctx.file_exists(tzfile):
        fail("given timezone %s is not available" % name)

    # Set timezone
    res = ctx.run(["chtz", name], mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would set timezone to " + name}
    if res.rc != 0:
        fail("failed to set timezone: " + res.stderr)

    return {"changed": True, "msg": "timezone updated"}
