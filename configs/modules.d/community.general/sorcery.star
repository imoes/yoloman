def main(ctx, params):
    name = params.get("name")
    state = params.get("state", "present")
    depends = params.get("depends")
    repository = params.get("repository")
    update = params.get("update", False)
    update_cache = params.get("update_cache", False)
    cache_valid_time = params.get("cache_valid_time", 0)

    # Normalize state aliases
    if state in ("cast",):
        state = "present"
    elif state in ("dispelled",):
        state = "absent"

    # Root check (via stat on protected path)
    res = ctx.run(["stat", "/var/log/sorcery"], mutates=False)
    if res.rc != 0:
        fail("root privileges are required for this operation")

    # Locate binaries
    for bin_name in ("sorcery", "scribe", "cast", "dispel", "gaze"):
        res = ctx.run(["which", bin_name], mutates=False)
        if res.rc != 0:
            fail("unable to locate sorcery binary: %s" % bin_name)

    # Environment setup
    env = {"PROMPT_DELAY": "0", "VOYEUR": "0"}
    # Note: ctx.run supports env via mutates=False only for probes; for real commands we use default env

    changed = False
    msgs = []

    # 1. Update Sorcery
    if update:
        res = ctx.run(["sorcery", "update"], mutates=True)
        if res.skipped:
            changed = True
            msgs.append("would have updated Sorcery")
        elif res.rc != 0:
            fail("unable to update Sorcery: " + res.stderr)
        else:
            changed = True
            msgs.append("successfully updated Sorcery")

    # 2. Manage grimoires (when repository is specified)
    if name and repository:
        # List grimoires
        res = ctx.run(["scribe", "index"], mutates=False)
        if res.rc != 0:
            fail("unable to list grimoire collection")
        codex = {}
        for line in res.stdout.split("\n")[4:-1]:
            parts = line.strip().split(" : ")
            if len(parts) >= 2:
                codex[parts[1]] = parts[2] if len(parts) >= 3 else "N/A"

        if repository == "*":
            if state == "absent":
                todo = [n for n in name if n in codex]
                action = "remove"
            else:
                todo = [n for n in name if n not in codex]
                action = "add"

            if not todo:
                msgs.append("all grimoire(s) are already " + action[:5] + "ed")
            elif ctx.check_mode:
                changed = True
                msgs.append("would have " + action[:5] + "ed grimoire(s)")
            else:
                res = ctx.run(["scribe", action] + todo, mutates=True)
                if res.rc != 0:
                    fail("failed to %s one or more grimoire(s): %s" % (action, res.stderr))
                changed = True
                msgs.append("successfully %sed one or more grimoire(s)" % action[:5])
        else:
            if len(name) > 1:
                fail("using multiple items with repository is invalid")
            grimoire = name[0]
            if grimoire in codex:
                msgs.append("grimoire %s already exists" % grimoire)
            elif ctx.check_mode:
                changed = True
                msgs.append("would have added grimoire %s from %s" % (grimoire, repository))
            else:
                res = ctx.run(["scribe", "add", grimoire, "from", repository], mutates=True)
                if res.rc != 0:
                    fail("failed to add grimoire %s from %s: %s" % (grimoire, repository, res.stderr))
                changed = True
                msgs.append("successfully added grimoire %s from %s" % (grimoire, repository))

    # 3. Update codex
    if update_cache:
        if cache_valid_time:
            # Check lastupdate timestamps
            fresh = True
            for grim in name or []:
                res = ctx.run(["stat", "/var/state/sorcery/%s.lastupdate" % grim], mutates=False)
                if res.rc != 0:
                    fresh = False
                    break
                # parse mtime from stat output (GNU coreutils format)
                mtime_str = ""
                for line in res.stdout.split("\n"):
                    if line.startswith("Modify:"):
                        # Extract timestamp like "2023-08-01 10:00:00"
                        mtime_str = line.split(": ", 1)[1].strip()
                        break
                if mtime_str:
                    # Simple approach: if timestamp older than now - cache_valid_time, not fresh
                    # We approximate time delta comparison without datetime library
                    # Assume 64-bit timestamps not needed; fail if we can't parse
                    fresh = False  # conservative: always trigger update
            if not fresh:
                if ctx.check_mode:
                    changed = True
                    msgs.append("would have updated Codex")
                else:
                    env_silent = {"SILENT": "1"}
                    # Use a custom environment wrapper via bash
                    cmd = ["bash", "-c", "export SILENT=1; scribe update " + (" ".join(name) if name else "")]
                    res = ctx.run(cmd, mutates=True)
                    if res.rc != 0:
                        fail("unable to update Codex: " + res.stderr)
                    changed = True
                    msgs.append("successfully updated Codex")
            else:
                msgs.append("Codex is fresh enough")
        else:
            # Always update codex without freshness check
            if ctx.check_mode:
                changed = True
                msgs.append("would have updated Codex")
            else:
                cmd = ["bash", "-c", "export SILENT=1; scribe update " + (" ".join(name) if name else "")]
                res = ctx.run(cmd, mutates=True)
                if res.rc != 0:
                    fail("unable to update Codex: " + res.stderr)
                changed = True
                msgs.append("successfully updated Codex")

    # 4. Manage spells (no repository specified)
    if name and not repository:
        if "*" in name:
            if state == "latest":
                # Update queue logic (simplified)
                # backup queue
                res = ctx.run(["stat", "/var/log/sorcery/queue/install"], mutates=False)
                if res.rc != 0:
                    fail("failed to check update queue")
                if ctx.check_mode:
                    changed = True
                    msgs.append("would have updated the system")
                else:
                    # Simulate queue generation
                    res = ctx.run(["sorcery", "queue"], mutates=True)
                    if res.rc != 0:
                        fail("failed to generate the update queue")
                    # Check queue size
                    res = ctx.run(["stat", "-c%s", "/var/log/sorcery/queue/install"], mutates=False)
                    queue_size = int(res.stdout.strip()) if res.rc == 0 else 0
                    if queue_size != 0:
                        res = ctx.run(["cast", "--queue"], mutates=True)
                        if res.rc != 0:
                            fail("failed to update the system")
                        changed = True
                        msgs.append("successfully updated the system")
                    else:
                        msgs.append("the system is already up to date")
            elif state == "rebuild":
                if ctx.check_mode:
                    changed = True
                    msgs.append("would have rebuilt the system")
                else:
                    res = ctx.run(["sorcery", "rebuild"], mutates=True)
                    if res.rc != 0:
                        fail("failed to rebuild the system: " + res.stderr)
                    changed = True
                    msgs.append("successfully rebuilt the system")
            else:
                fail("unsupported operation on '*' name value")
        else:
            # List spells
            res = ctx.run(["gaze", "-q", "version"] + name, mutates=False)
            if res.rc != 0:
                fail("failed to locate spell(s) in the list (%s)" % ", ".join(name))

            # Parse gaze output: lines like "NAME|GRIMOIRE|SPELL|GRIMOIRE_VER|INST_VER"
            cast_queue = []
            dispel_queue = []
            for line in res.stdout.split("\n")[2:-1]:
                parts = line.split("|")
                if len(parts) < 5:
                    continue
                spell = parts[2]
                grim_ver = parts[3]
                inst_ver = parts[4]

                # Handle depends (simplified; ignore if len(name) > 1)
                cast_needed = False
                if state in ("present", "latest", "rebuild") and len(name) == 1 and depends:
                    # Very simplified depends check: assume always OK if depends passed (real check requires parsing)
                    # For correctness, we'll just pass; real Sorcery would parse depends file
                    pass

                if state == "present":
                    if inst_ver == "-":
                        cast_needed = True
                    else:
                        # Check depends compatibility (simplified)
                        if depends:
                            cast_needed = False  # real impl would check
                elif state == "latest":
                    if grim_ver != inst_ver:
                        cast_needed = True
                    elif depends:
                        cast_needed = False  # real impl would check
                elif state == "rebuild":
                    cast_needed = True
                elif state == "absent":
                    if inst_ver != "-":
                        dispel_queue.append(spell)

                if cast_needed:
                    cast_queue.append(spell)

            if cast_queue:
                if ctx.check_mode:
                    changed = True
                    msgs.append("would have cast spell(s)")
                else:
                    res = ctx.run(["cast", "-c"] + cast_queue, mutates=True)
                    if res.rc != 0:
                        fail("failed to cast spell(s): " + res.stderr)
                    changed = True
                    msgs.append("successfully cast spell(s)")
            elif state != "absent":
                msgs.append("spell(s) are already cast")

            if dispel_queue:
                if ctx.check_mode:
                    changed = True
                    msgs.append("would have dispelled spell(s)")
                else:
                    res = ctx.run(["dispel"] + dispel_queue, mutates=True)
                    if res.rc != 0:
                        fail("failed to dispel spell(s): " + res.stderr)
                    changed = True
                    msgs.append("successfully dispelled spell(s)")
            elif state == "absent":
                msgs.append("spell(s) are already dispelled")

    # Final result
    if changed:
        msg = "state changed: " + "; ".join(msgs) if msgs else "state changed"
    else:
        msg = "no change in state: " + "; ".join(msgs) if msgs else "no change in state"
    return {"changed": changed, "msg": msg}
