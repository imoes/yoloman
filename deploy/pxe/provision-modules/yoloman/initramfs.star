def main(ctx, params):
    actions = []
    changed = False

    # 1. Comment out swap entries in /etc/fstab
    if ctx.file_exists("/etc/fstab"):
        fstab_content = ctx.file_read("/etc/fstab")
        new_lines = []
        fstab_changed = False
        for line in fstab_content.split("\n"):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                new_lines.append(line)
                continue

            fields = stripped.split()
            if len(fields) >= 3 and (fields[1] == "swap" or fields[2] == "swap"):
                new_lines.append("#" + line)
                fstab_changed = True
            else:
                new_lines.append(line)

        if fstab_changed:
            new_content = "\n".join(new_lines)
            if new_content != fstab_content:
                changed = ctx.file_write("/etc/fstab", new_content)
                if changed:
                    actions.append("commented_swap_in_fstab")
    else:
        actions.append("fstab_not_present")

    # 2. Ensure /etc/initramfs-tools/conf.d/resume contains RESUME=none
    resume_dir = "/etc/initramfs-tools/conf.d"
    resume_file = resume_dir + "/resume"
    expected_resume = "RESUME=none\n"

    ctx.run(["mkdir", "-p", resume_dir], mutates=True)

    resume_exists = ctx.file_exists(resume_file)
    resume_content = ctx.file_read(resume_file) if resume_exists else ""
    if resume_content != expected_resume:
        resume_changed = ctx.file_write(resume_file, expected_resume)
        if resume_changed:
            actions.append("set_resume_none")
            changed = True

    # 3. Rebuild initramfs
    rebuild_msg = None
    if ctx.check_mode:
        actions.append("would_rebuild_initramfs")
        return {"changed": True, "msg": "would rebuild initramfs", "data": {"actions": actions}}

    res = ctx.run(["update-initramfs", "-u", "-k", "all"], mutates=True)
    if res.rc == 0:
        rebuild_msg = "rebuild_ok"
    else:
        actions.append("fallback_to_default_kernel")
        res = ctx.run(["update-initramfs", "-u"], mutates=True)
        if res.rc == 0:
            rebuild_msg = "rebuild_ok"
        else:
            fail("failed to rebuild initramfs: " + res.stderr)

    if rebuild_msg:
        actions.append(rebuild_msg)

    # The initramfs was rebuilt (not idempotent), so this run always changed the system.
    return {
        "changed": True,
        "msg": "initramfs updated for chroot: " + ";".join(actions),
        "data": {"actions": actions}
    }
