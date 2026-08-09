def main(ctx, params):
    names = params["name"]
    state = params.get("state", "present")
    classic = params.get("classic", False)
    channel = params.get("channel")
    options = params.get("options")
    dangerous = params.get("dangerous", False)

    if len(names) == 0:
        fail("name list must not be empty")

    # Determine channel normalization
    def normalize_channel(ch):
        if ch == None or ch == "":
            return "stable"
        if "/" not in ch:
            return "latest/" + ch
        return ch

    norm_channel = normalize_channel(channel)

    # Probe installed snaps and channels
    res = ctx.run(["snap", "list"], mutates=False)
    if res.rc != 0:
        fail("failed to list snaps: " + res.stderr)

    installed = {}
    lines = res.stdout.strip().split("\n")
    if len(lines) > 1:
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 4:
                name = parts[0]
                ch = parts[3]
                installed[name] = ch

    # Build status map
    snap_status = {}
    for name in names:
        if name not in installed:
            snap_status[name] = "not_installed"
        else:
            ch = installed[name]
            if norm_channel != "stable" and ch not in (norm_channel, "latest/" + norm_channel.split("/")[1]):
                snap_status[name] = "channel_mismatch"
            else:
                snap_status[name] = "installed"

    # Process based on state
    if state == "absent":
        to_remove = [name for name in names if snap_status[name] != "not_installed"]
        if len(to_remove) == 0:
            return {"changed": False, "msg": "no snaps to remove"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove " + ", ".join(to_remove)}
        res = ctx.run(["snap", "remove"] + to_remove, mutates=True)
        if res.rc != 0:
            fail("failed to remove snaps: " + res.stderr)
        return {"changed": True, "msg": "removed " + ", ".join(to_remove), "snaps_removed": to_remove}

    elif state in ["enabled", "disabled"]:
        # Get current enabled status
        def is_enabled(name):
            res = ctx.run(["snap", "list", name], mutates=False)
            if res.rc != 0:
                return None
            lines = res.stdout.strip().split("\n")
            if len(lines) < 2:
                return None
            notes = lines[1].split()[-1]
            # disabled appears in notes if disabled
            return "disabled" not in notes.split(",")

        actionable = []
        if state == "enabled":
            actionable = [name for name in names if snap_status[name] != "not_installed" and not is_enabled(name)]
        else:  # disabled
            actionable = [name for name in names if snap_status[name] != "not_installed" and is_enabled(name)]

        if len(actionable) == 0:
            return {"changed": False, "msg": "snaps already in desired state"}

        if ctx.check_mode:
            verb = "would enable" if state == "enabled" else "would disable"
            return {"changed": True, "msg": verb + " " + ", ".join(actionable)}

        res = ctx.run(["snap", state] + actionable, mutates=True)
        if res.rc != 0:
            fail("failed to " + state + " snaps: " + res.stderr)

        result = {"changed": True, "msg": state + "d " + ", ".join(actionable)}
        if state == "enabled":
            result["snaps_enabled"] = actionable
        else:
            result["snaps_disabled"] = actionable
        return result

    elif state == "present":
        # Separate install and refresh tasks
        to_install = [name for name in names if snap_status[name] == "not_installed"]
        to_refresh = [name for name in names if snap_status[name] == "channel_mismatch"]

        # If channel is default stable, no refresh needed
        if norm_channel == "stable":
            to_refresh = []

        changes_made = False
        installed_list = []
        refreshed_list = []

        # Install
        if len(to_install) > 0:
            changes_made = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would install " + ", ".join(to_install)}

            # Build install args
            install_args = ["snap", "install"]
            if dangerous:
                install_args.append("--dangerous")
            if classic:
                install_args.append("--classic")
            if norm_channel != "stable":
                install_args.extend(["--channel", norm_channel])
            install_args.extend(to_install)

            res = ctx.run(install_args, mutates=True)
            if res.rc != 0:
                fail("failed to install snaps: " + res.stderr)
            installed_list = to_install

        # Refresh
        if len(to_refresh) > 0:
            changes_made = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would refresh " + ", ".join(to_refresh)}

            refresh_args = ["snap", "refresh"]
            if norm_channel != "stable":
                refresh_args.extend(["--channel", norm_channel])
            refresh_args.extend(to_refresh)

            res = ctx.run(refresh_args, mutates=True)
            if res.rc != 0:
                fail("failed to refresh snaps: " + res.stderr)
            refreshed_list = to_refresh

        # Handle options if any (only for active snaps, not installed)
        if options != None:
            # For each option, parse snap:key=value or key=value
            set_re = "\\A(?:(\\S+):)?(\\S+)\\s*=\\s*(\\S*)\\Z"
            set_re_match = lambda s: (
                len(s.split(":", 1)) == 2 and (s.split(":", 1)[0] if ":" in s else None),
                s.split(":", 1)[-1].split("=", 1)[0] if "=" in s.split(":", 1)[-1] else None,
                s.split(":", 1)[-1].split("=", 1)[1].strip() if "=" in s.split(":", 1)[-1] else None
            ) if ("=" in s.split(":", 1)[-1]) else None

            def parse_option(opt_str):
                parts = opt_str.strip().split("=", 1)
                if len(parts) != 2:
                    return None
                key = parts[0].strip()
                value = parts[1].strip()
                snap_name = None
                if ":" in key:
                    parts2 = key.split(":", 1)
                    snap_name = parts2[0].strip()
                    key = parts2[1].strip()
                return snap_name, key, value

            for opt_str in options:
                parsed = parse_option(opt_str.strip())
                if parsed == None:
                    fail("invalid option format: " + opt_str)
                snap_prefix, key, value = parsed

                # Determine which snaps to apply
                target_snaps = []
                if snap_prefix != None:
                    if snap_prefix not in names:
                        fail("option refers to unknown snap: " + snap_prefix)
                    target_snaps = [snap_prefix]
                else:
                    target_snaps = names

                for snap_name in target_snaps:
                    # Only active (installed) snaps
                    if snap_status[snap_name] == "not_installed":
                        continue

                    # Check current value
                    res = ctx.run(["snap", "get", snap_name, key], mutates=False)
                    if res.rc != 0 and "has no configuration" in res.stderr:
                        # No config; set it
                        if not ctx.check_mode:
                            res = ctx.run(["snap", "set", snap_name, key + "=" + value], mutates=True)
                            if res.rc != 0:
                                fail("failed to set option on snap " + snap_name + ": " + res.stderr)
                        changes_made = True
                    elif res.rc == 0:
                        # Compare
                        lines = res.stdout.strip().split("\n")
                        if len(lines) > 0 and lines[0].strip() != value:
                            if not ctx.check_mode:
                                res = ctx.run(["snap", "set", snap_name, key + "=" + value], mutates=True)
                                if res.rc != 0:
                                    fail("failed to set option on snap " + snap_name + ": " + res.stderr)
                            changes_made = True

        if not changes_made:
            return {"changed": False, "msg": "all snaps already in desired state"}

        msg_parts = []
        if len(installed_list) > 0:
            msg_parts.append("installed " + ", ".join(installed_list))
        if len(refreshed_list) > 0:
            msg_parts.append("refreshed " + ", ".join(refreshed_list))
        return {
            "changed": True,
            "msg": "; ".join(msg_parts),
            "snaps_installed": installed_list if len(installed_list) > 0 else None,
            "snaps_refreshed": refreshed_list if len(refreshed_list) > 0 else None,
            "classic": classic if len(to_install) > 0 else False,
            "channel": norm_channel if len(to_install) > 0 else None,
        }

    else:
        fail("unsupported state: " + state)
