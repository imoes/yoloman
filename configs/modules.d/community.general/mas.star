def main(ctx, params):
    # Extract parameters
    app_ids = params.get("id", [])
    state = params.get("state", "present")
    upgrade_all = params.get("upgrade_all", False)

    # Ensure mas binary exists and is recent enough
    res = ctx.run(["mas", "version"])
    if res.rc != 0 or not res.stdout.strip():
        fail("Required `mas` tool is not installed or not working")
    version = res.stdout.strip()
    # Compare versions manually (simple numeric comparison for major.minor.patch)
    def parse_version(v):
        parts = v.split(".")
        return [int(p) for p in parts[:3]] + [0] * (3 - len(parts))
    v_parts = parse_version(version)
    if v_parts < [1, 5, 0]:
        fail("`mas` tool version 1.5.0+ needed, got " + version)

    # Check sign-in status (skip for macOS 12.0+; use facts for OS version)
    facts = ctx.facts()
    os_family = facts.get("os_family", "")
    # We can't get exact macOS version string easily in Starlark,
    # but we know only macOS 12+ has the issue; assume macOS if os_family == "darwin"
    if os_family == "darwin":
        # For safety, we skip the check on macOS entirely if we can't determine version.
        # The user must be signed in via GUI on macOS 12+.
        pass
    else:
        # Non-macOS: fail early
        fail("mas module only supports macOS")

    # Get installed apps list (read-only)
    res = ctx.run(["mas", "list"])
    installed = []
    if res.rc == 0 and res.stdout.strip():
        for line in res.stdout.strip().splitlines():
            line = line.strip()
            if line.startswith("No installed apps found"):
                break
            parts = line.split(" ", 1)
            if len(parts) >= 1 and parts[0].isdigit():
                installed.append(int(parts[0]))

    # Get outdated apps list (read-only)
    res = ctx.run(["mas", "outdated"])
    outdated = []
    if res.rc == 0 and res.stdout.strip():
        for line in res.stdout.strip().splitlines():
            line = line.strip()
            if line.startswith("No installed apps found"):
                break
            parts = line.split(" ", 1)
            if len(parts) >= 1 and parts[0].isdigit():
                outdated.append(int(parts[0]))

    # Track counts
    count_install = 0
    count_upgrade = 0
    count_uninstall = 0
    changed = False

    # Normalize app_ids to a set of unique integers
    unique_ids = list(set(app_ids))

    # Process per-app operations
    for app_id in sorted(unique_ids):
        if state == "present":
            if app_id not in installed:
                if ctx.check_mode:
                    changed = True
                    count_install += 1
                    continue
                res = ctx.run(["mas", "install", str(app_id)], mutates=True)
                if res.rc != 0:
                    fail("Error installing app " + str(app_id) + ": " + res.stderr)
                count_install += 1
                changed = True

        elif state == "absent":
            if app_id in installed:
                # Require become/root (we cannot check UID in Starlark, so we expect caller to use become)
                # Note: We'll assume user handles become: true if needed.
                if ctx.check_mode:
                    changed = True
                    count_uninstall += 1
                    continue
                res = ctx.run(["mas", "uninstall", str(app_id)], mutates=True)
                if res.rc != 0:
                    fail("Error uninstalling app " + str(app_id) + ": " + res.stderr)
                count_uninstall += 1
                changed = True

        elif state == "latest":
            if app_id not in installed:
                if ctx.check_mode:
                    changed = True
                    count_install += 1
                    continue
                res = ctx.run(["mas", "install", str(app_id)], mutates=True)
                if res.rc != 0:
                    fail("Error installing app " + str(app_id) + ": " + res.stderr)
                count_install += 1
                changed = True
            elif app_id in outdated:
                if ctx.check_mode:
                    changed = True
                    count_upgrade += 1
                    continue
                res = ctx.run(["mas", "upgrade", str(app_id)], mutates=True)
                if res.rc != 0:
                    fail("Error upgrading app " + str(app_id) + ": " + res.stderr)
                count_upgrade += 1
                changed = True

    # Upgrade all outdated if requested
    if upgrade_all and outdated:
        if ctx.check_mode:
            changed = True
            count_upgrade += len(outdated)
        else:
            res = ctx.run(["mas", "upgrade"], mutates=True)
            if res.rc != 0:
                fail("Error upgrading all apps: " + res.stderr)
            count_upgrade += len(outdated)
            changed = True

    # Build msg
    msgs = []
    if count_install > 0:
        msgs.append("Installed " + str(count_install) + " app(s)")
    if count_upgrade > 0:
        msgs.append("Upgraded " + str(count_upgrade) + " app(s)")
    if count_uninstall > 0:
        msgs.append("Uninstalled " + str(count_uninstall) + " app(s)")

    if msgs:
        msg = ", ".join(msgs)
    else:
        msg = "No changes required"

    return {"changed": changed, "msg": msg}
