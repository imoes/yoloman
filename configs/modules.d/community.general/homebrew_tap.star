def main(ctx, params):
    taps = params["name"]
    state = params.get("state", "present")
    url = params.get("url")
    path = params.get("path", "/usr/local/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin")
    
    # Split path list
    path_dirs = path.split(":") if path else []
    
    # Find brew executable
    brew_path = None
    for dir_path in path_dirs:
        if ctx.file_exists(dir_path + "/brew"):
            brew_path = dir_path + "/brew"
            break
        elif ctx.file_exists(dir_path + "/brew"):
            brew_path = dir_path + "/brew"
            break
    if brew_path == None:
        fail("brew executable not found in path: " + path)
    
    # Validate taps and url combination
    if url != None and len(taps) > 1:
        fail("List of multiple taps may not be provided with 'url' option.")
    
    # Helper: validate tap format
    def valid_tap(tap):
        parts = tap.split("/")
        if len(parts) != 2:
            return False
        for p in parts:
            if not p:
                return False
            for c in p:
                if not (c.isalnum() or c == '-' or c == '_'):
                    return False
        return True
    
    # Helper: check if tap is already tapped
    def is_tapped(tap):
        res = ctx.run([brew_path, "tap"], mutates=False)
        if res.rc != 0:
            return False
        taps_list = []
        for line in res.stdout.split("\n"):
            t = line.strip().lower()
            if t:
                # Normalize: remove 'homebrew-' prefix
                norm = t.replace("homebrew-", "")
                taps_list.append(norm)
        tap_name = tap.lower().replace("homebrew-", "")
        return tap_name in taps_list
    
    # Helper: add single tap
    def do_add_tap(tap, tap_url):
        if not valid_tap(tap):
            return (True, "", "not a valid tap: %s" % tap)
        if is_tapped(tap):
            return (False, False, "already tapped: %s" % tap)
        if ctx.check_mode:
            return (False, True, "would tap " + tap)
        if tap_url != None:
            res = ctx.run([brew_path, "tap", tap, tap_url], mutates=True)
        else:
            res = ctx.run([brew_path, "tap", tap], mutates=True)
        if res.skipped:
            return (False, True, "would tap " + tap)
        if res.rc == 0 and is_tapped(tap):
            return (False, True, "successfully tapped: %s" % tap)
        return (True, "", "failed to tap: %s due to %s" % (tap, res.stderr if res.stderr else "unknown error"))
    
    # Helper: remove single tap
    def do_remove_tap(tap):
        if not valid_tap(tap):
            return (True, "", "not a valid tap: %s" % tap)
        if not is_tapped(tap):
            return (False, False, "already untapped: %s" % tap)
        if ctx.check_mode:
            return (False, True, "would untap " + tap)
        res = ctx.run([brew_path, "untap", tap], mutates=True)
        if res.skipped:
            return (False, True, "would untap " + tap)
        if res.rc == 0 and not is_tapped(tap):
            return (False, True, "successfully untapped: %s" % tap)
        return (True, "", "failed to untap: %s due to %s" % (tap, res.stderr if res.stderr else "unknown error"))
    
    # State processing
    if state == "present":
        if url == None:
            # Add multiple taps
            changed_count = 0
            failed = False
            msg_parts = []
            for tap in taps:
                failed, changed, msg = do_add_tap(tap, None)
                if failed:
                    break
                if changed:
                    changed_count += 1
                msg_parts.append(msg)
            if failed:
                fail(msg)
            changed = changed_count > 0
            if changed:
                return {"changed": True, "msg": "added: %d, unchanged: %d" % (changed_count, len(taps) - changed_count)}
            else:
                return {"changed": False, "msg": "added: %d, unchanged: %d" % (changed_count, len(taps) - changed_count)}
        else:
            # Add single tap with URL
            failed, changed, msg = do_add_tap(taps[0], url)
            if failed:
                fail(msg)
            return {"changed": changed, "msg": msg}
    
    elif state == "absent":
        removed_count = 0
        failed = False
        msg_parts = []
        for tap in taps:
            failed, changed, msg = do_remove_tap(tap)
            if failed:
                break
            if changed:
                removed_count += 1
        if failed:
            fail(msg)
        changed = removed_count > 0
        if changed:
            return {"changed": True, "msg": "removed: %d, unchanged: %d" % (removed_count, len(taps) - removed_count)}
        else:
            return {"changed": False, "msg": "removed: %d, unchanged: %d" % (removed_count, len(taps) - removed_count)}
    
    fail("unsupported state: " + state)
