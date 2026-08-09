def main(ctx, params):
    path = params["path"]
    state = params.get("state", "present")
    release = params.get("release")
    releases_path_name = params.get("releases_path", "releases")
    shared_path_name = params.get("shared_path", "shared")
    current_path_name = params.get("current_path", "current")
    keep_releases = params.get("keep_releases", 5)
    clean = params.get("clean", True)
    unfinished_filename = params.get("unfinished_filename", "DEPLOY_UNFINISHED")

    # Helper: path composition
    def relpath(subdir):
        return subdir if subdir.startswith("/") else path + "/" + subdir

    # Helper: read dir entries (returns list of names)
    def listdir(p):
        res = ctx.run(["ls", "-1", p])
        if res.rc != 0:
            fail("failed to list directory " + p + ": " + res.stderr)
        return [l for l in res.stdout.splitlines() if l]

    # Helper: check if symlink exists and points to target
    def is_symlink_to(link, target):
        if not ctx.file_exists(link):
            return False
        link_stat = ctx.stat(link)
        if link_stat == None or not link_stat.get("is_link", False):
            return False
        real = ctx.run(["readlink", "-f", link])
        if real.rc != 0:
            fail("readlink failed for " + link + ": " + real.stderr)
        normalized_target = ctx.run(["readlink", "-f", target])
        if normalized_target.rc != 0:
            fail("readlink failed for target " + target + ": " + normalized_target.stderr)
        return real.stdout.strip() == normalized_target.stdout.strip()

    # Facts gathering
    current_path = relpath(current_path_name)
    releases_path = relpath(releases_path_name)
    if shared_path_name != "":
        shared_path = relpath(shared_path_name)
    else:
        shared_path = None

    previous_release, previous_release_path = None, None
    if ctx.file_exists(current_path):
        link_stat = ctx.stat(current_path)
        if link_stat == None or not link_stat.get("is_link", False):
            fail(current_path + " exists but is not a symbolic link")
        real = ctx.run(["readlink", "-f", current_path])
        if real.rc != 0:
            fail("readlink failed for " + current_path + ": " + real.stderr)
        previous_release_path = real.stdout.strip()
        if previous_release_path:
            previous_release = previous_release_path.split("/")[-1]

    # Auto-generate release if missing and state allows
    if release == None and (state == "query" or state == "present"):
        res = ctx.run(["date", "+%Y%m%d%H%M%S"])
        if res.rc != 0:
            fail("failed to generate timestamp")
        release = res.stdout.strip()

    new_release_path = None
    if release != None:
        new_release_path = releases_path + "/" + release

    facts = {
        "project_path": path,
        "current_path": current_path,
        "releases_path": releases_path,
        "shared_path": shared_path,
        "previous_release": previous_release,
        "previous_release_path": previous_release_path,
        "new_release": release,
        "new_release_path": new_release_path,
        "unfinished_filename": unfinished_filename
    }

    # Return facts only for query or when state=present without changes
    if state == "query":
        return {"changed": False, "msg": "facts retrieved", "ansible_facts": {"deploy_helper": facts}}

    if state == "present":
        # Check symlink target is valid directory
        if ctx.file_exists(current_path):
            link_stat = ctx.stat(current_path)
            if link_stat == None or not link_stat.get("is_link", False):
                fail(current_path + " exists but is not a symbolic link")

        # Create root, releases, shared
        changes = 0
        if not ctx.file_exists(path):
            if ctx.check_mode:
                changes += 1
            else:
                res = ctx.run(["mkdir", "-p", path])
                if res.rc != 0:
                    fail("failed to create root path " + path + ": " + res.stderr)
                changes += 1

        if not ctx.file_exists(releases_path):
            if ctx.check_mode:
                changes += 1
            else:
                res = ctx.run(["mkdir", "-p", releases_path])
                if res.rc != 0:
                    fail("failed to create releases path " + releases_path + ": " + res.stderr)
                changes += 1

        if shared_path != None and not ctx.file_exists(shared_path):
            if ctx.check_mode:
                changes += 1
            else:
                res = ctx.run(["mkdir", "-p", shared_path])
                if res.rc != 0:
                    fail("failed to create shared path " + shared_path + ": " + res.stderr)
                changes += 1

        return {"changed": changes > 0, "msg": "directory structure created", "ansible_facts": {"deploy_helper": facts}}

    if state == "finalize":
        if keep_releases <= 0:
            fail("'keep_releases' should be at least 1")

        if new_release_path == None:
            fail("release is required for state=finalize")

        if not ctx.file_exists(new_release_path):
            fail("new_release_path does not exist: " + new_release_path)

        changes = 0
        # Remove unfinished file from new_release_path
        unfinished_file = new_release_path + "/" + unfinished_filename
        if ctx.file_exists(unfinished_file):
            if ctx.check_mode:
                changes += 1
            else:
                res = ctx.run(["rm", "-f", unfinished_file])
                if res.rc != 0:
                    fail("failed to remove " + unfinished_file + ": " + res.stderr)
                changes += 1

        # Create/recreate symlink
        if not is_symlink_to(current_path, new_release_path):
            if ctx.check_mode:
                changes += 1
            else:
                # Remove existing link if any (not a symlink check above handled)
                if ctx.file_exists(current_path):
                    link_stat = ctx.stat(current_path)
                    if link_stat != None and link_stat.get("is_link", False):
                        res = ctx.run(["rm", "-f", current_path])
                        if res.rc != 0:
                            fail("failed to remove existing symlink " + current_path + ": " + res.stderr)
                res = ctx.run(["ln", "-s", new_release_path, current_path])
                if res.rc != 0:
                    fail("failed to create symlink " + current_path + " -> " + new_release_path + ": " + res.stderr)
                changes += 1

        if clean:
            # Remove unfinished builds in releases
            if ctx.file_exists(releases_path):
                dirs = listdir(releases_path)
                for d in dirs:
                    release_full = releases_path + "/" + d
                    if ctx.file_exists(release_full) and ctx.file_exists(release_full + "/" + unfinished_filename):
                        if ctx.check_mode:
                            changes += 1
                        else:
                            res = ctx.run(["rm", "-rf", release_full])
                            if res.rc != 0:
                                fail("failed to remove unfinished build " + release_full + ": " + res.stderr)
                            changes += 1

            # Clean old releases, preserving new_release_path basename
            reserve_version = None
            if new_release_path != None:
                reserve_version = new_release_path.split("/")[-1]

            if ctx.file_exists(releases_path):
                dirs = listdir(releases_path)
                # Filter out reserve_version
                if reserve_version != None:
                    dirs = [d for d in dirs if d != reserve_version]

                # Sort by creation time (descending) — use ls -t
                # ls -t sorts by modification time (newest first)
                ls_res = ctx.run(["ls", "-t", releases_path])
                if ls_res.rc != 0:
                    fail("failed to list releases by time: " + ls_res.stderr)
                ordered = [x for x in ls_res.stdout.splitlines() if x]

                # Remove all but first keep_releases
                to_remove = ordered[keep_releases:]
                for d in to_remove:
                    release_full = releases_path + "/" + d
                    if ctx.file_exists(release_full):
                        if ctx.check_mode:
                            changes += 1
                        else:
                            res = ctx.run(["rm", "-rf", release_full])
                            if res.rc != 0:
                                fail("failed to remove old release " + release_full + ": " + res.stderr)
                            changes += 1

        return {"changed": changes > 0, "msg": "finalize completed", "ansible_facts": {"deploy_helper": facts}}

    if state == "clean":
        changes = 0

        # Remove unfinished builds in releases
        if ctx.file_exists(releases_path):
            dirs = listdir(releases_path)
            for d in dirs:
                release_full = releases_path + "/" + d
                if ctx.file_exists(release_full) and ctx.file_exists(release_full + "/" + unfinished_filename):
                    if ctx.check_mode:
                        changes += 1
                    else:
                        res = ctx.run(["rm", "-rf", release_full])
                        if res.rc != 0:
                            fail("failed to remove unfinished build " + release_full + ": " + res.stderr)
                        changes += 1

        # Remove old releases
        reserve_version = None
        if new_release_path != None:
            reserve_version = new_release_path.split("/")[-1]

        if ctx.file_exists(releases_path):
            dirs = listdir(releases_path)
            if reserve_version != None:
                dirs = [d for d in dirs if d != reserve_version]

            ls_res = ctx.run(["ls", "-t", releases_path])
            if ls_res.rc != 0:
                fail("failed to list releases by time: " + ls_res.stderr)
            ordered = [x for x in ls_res.stdout.splitlines() if x]

            to_remove = ordered[keep_releases:]
            for d in to_remove:
                release_full = releases_path + "/" + d
                if ctx.file_exists(release_full):
                    if ctx.check_mode:
                        changes += 1
                    else:
                        res = ctx.run(["rm", "-rf", release_full])
                        if res.rc != 0:
                            fail("failed to remove old release " + release_full + ": " + res.stderr)
                        changes += 1

        return {"changed": changes > 0, "msg": "clean completed", "ansible_facts": {"deploy_helper": facts}}

    if state == "absent":
        if ctx.file_exists(path):
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete " + path}
            res = ctx.run(["rm", "-rf", path])
            if res.rc != 0:
                fail("failed to delete " + path + ": " + res.stderr)
            return {"changed": True, "msg": "deleted " + path}
        return {"changed": False, "msg": path + " does not exist"}

    fail("unsupported state: " + state)
