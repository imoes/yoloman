def main(ctx, params):
    repo = params["repo"]
    dest = params.get("dest")
    revision = params.get("revision")
    force = params.get("force", False)
    purge = params.get("purge", False)
    update = params.get("update", True)
    clone = params.get("clone", True)
    executable = params.get("executable")

    # Determine hg executable
    if executable:
        hg_path = executable
    else:
        hg_path = "hg"

    # Validate dest requirement
    if dest == None and (clone or update):
        fail("the destination directory must be specified unless clone=false and update=false")

    hgrc_path = dest + "/.hg/hgrc" if dest else None

    # Helper functions (defined inside main to access ctx)
    def hg_run(args, mutates=False, ok_codes=[0]):
        return ctx.run([hg_path] + args, mutates=mutates, ok_codes=ok_codes)

    def get_revision(dest_dir):
        res = hg_run(["id", "-b", "-i", "-t", "-R", dest_dir])
        if res.rc != 0:
            fail("failed to get revision: " + res.stderr)
        return res.stdout.strip()

    def has_local_mods(rev_str):
        return "+" in rev_str

    def discard_changes(dest_dir):
        before = has_local_mods(get_revision(dest_dir))
        if not before:
            return False
        res = hg_run(["update", "-C", "-R", dest_dir, "-r", "."], mutates=True)
        if res.skipped:
            return True  # would discard
        if res.rc != 0:
            fail("failed to discard changes: " + res.stderr)
        after = has_local_mods(get_revision(dest_dir))
        return before and not after

    def purge_untracked(dest_dir):
        # First list untracked files
        res = hg_run(["purge", "--config", "extensions.purge=", "-R", dest_dir, "--print"])
        if res.rc != 0:
            fail("failed to list untracked files: " + res.stderr)
        if res.stdout.strip():
            res = hg_run(["purge", "--config", "extensions.purge=", "-R", dest_dir], mutates=True)
            if res.skipped:
                return True
            if res.rc != 0:
                fail("failed to purge: " + res.stderr)
            return True
        return False

    def cleanup(force_flag, purge_flag):
        cleaned = False
        if force_flag:
            cleaned = discard_changes(dest) or cleaned
        if purge_flag:
            cleaned = purge_untracked(dest) or cleaned
        return cleaned

    def at_revision(dest_dir, rev):
        if rev == None or len(rev) < 7:
            return False
        res = hg_run(["--debug", "id", "-i", "-R", dest_dir])
        if res.rc != 0:
            fail("failed to check at_revision: " + res.stderr)
        # Compare first 7+ characters of the output with revision
        out_id = res.stdout.strip()
        # hg id output format: "<hash>[+]"
        if out_id.startswith(rev):
            return True
        return False

    # Initial state checks
    changed = False
    cleaned = False
    before = ""
    after = ""

    # Check if clone=false and update=false
    if not clone and not update:
        # Just get remote revision info
        res = hg_run(["id", repo])
        if res.skipped:
            fail("skipped remote revision check in check_mode")
        if res.rc != 0:
            fail("failed to get remote revision: " + res.stderr)
        after = res.stdout.strip()
        return {"changed": False, "msg": "remote revision checked", "data": {"after": after}}

    # Check if repository exists locally
    if not ctx.file_exists(hgrc_path):
        if clone:
            # Clone needed
            args = ["clone", repo, dest]
            if revision:
                args += ["-r", revision]
            res = hg_run(args, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would clone repository", "data": {"before": "", "after": ""}}
            if res.rc != 0:
                fail("failed to clone: " + res.stderr)
            changed = True
            before = ""
            after = get_revision(dest)
        else:
            return {"changed": False, "msg": "repository does not exist and clone=false", "data": {"before": "", "after": ""}}
    else:
        # Repository exists locally
        before = get_revision(dest)

        if not update:
            # No update needed, just report current state
            return {"changed": False, "msg": "repository exists and update=false", "data": {"before": before, "after": before}}
        elif at_revision(dest, revision):
            # No update needed, but check for force/purge
            cleaned = cleanup(force, purge)
            after = get_revision(dest)
        else:
            # Update required
            # First cleanup if needed
            cleaned = cleanup(force, purge)

            # Pull
            res = hg_run(["pull", "-R", dest, repo], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would pull and update repository", "data": {"before": before, "after": ""}}
            if res.rc != 0:
                fail("failed to pull: " + res.stderr)

            # Update
            args = ["update", "-R", dest]
            if revision:
                args += ["-r", revision]
            res = hg_run(args, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would update repository", "data": {"before": before, "after": ""}}
            if res.rc != 0:
                fail("failed to update: " + res.stderr)
            changed = True

        after = get_revision(dest)

    # Final status determination
    if before != after or cleaned:
        changed = True

    return {
        "changed": changed,
        "msg": "repository updated" if changed else "repository already in desired state",
        "data": {"before": before, "after": after, "cleaned": cleaned}
    }
