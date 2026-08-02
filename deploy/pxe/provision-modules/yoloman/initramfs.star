# yoloman.initramfs — neutralise the source's swap/resume, then rebuild the initramfs.
#
# A PROVISIONING-ONLY module (baked into the PE, not the builtin agent). Run INSIDE the restored
# root's chroot. partclone images filesystems only, so the source's swap LV is NOT captured and does
# not exist on the target. Left alone, the source's fstab swap entry + the initramfs resume=<old-swap>
# make systemd wait ~90s each boot ("waiting for suspend/resume device"), stalling before login. So:
#   1. comment out swap lines in /etc/fstab,
#   2. pin RESUME=none (drops the stale resume device),
#   3. rebuild the initramfs for THIS machine (matches its real devices, drops the stale resume).
# Idempotent: re-running finds swap already commented + RESUME already none and only rebuilds.
# Contract: {changed, msg, data}.

def main(ctx, params):
    changed = False
    done = []

    # 1. Comment active swap lines in fstab.
    fstab = "/etc/fstab"
    if ctx.file_exists(fstab):
        old = ctx.file_read(fstab)
        out = []
        for line in old.split("\n"):
            s = line.strip()
            # an active (non-comment) line whose second field or an fs-type field is 'swap'
            if s and not s.startswith("#") and _is_swap_line(s):
                out.append("#" + line)
            else:
                out.append(line)
        new = "\n".join(out)
        if new != old:
            ctx.file_write(fstab, new, mode="0644")
            changed = True
            done.append("commented swap in fstab")

    # 2. Pin RESUME=none.
    resume = "/etc/initramfs-tools/conf.d/resume"
    want = "RESUME=none\n"
    cur = ctx.file_read(resume) if ctx.file_exists(resume) else ""
    if cur != want:
        ctx.run(["mkdir", "-p", "/etc/initramfs-tools/conf.d"], mutates=True)
        ctx.file_write(resume, want, mode="0644")
        changed = True
        done.append("pinned RESUME=none")

    # 3. Rebuild the initramfs (always — cheap, and the point of the module).
    res = ctx.run(["sh", "-c", "update-initramfs -u -k all || update-initramfs -u"], mutates=True)
    if res.rc != 0:
        fail("update-initramfs failed: %s" % res.stderr)
    done.append("rebuilt initramfs")

    return {
        "changed": True,
        "msg": "neutralised source swap/resume and rebuilt initramfs (%s)" % ", ".join(done),
        "data": {"actions": done},
    }


# A swap fstab line: fields are <spec> <mount> <type> ...; either the mount point or the type is 'swap'.
def _is_swap_line(line):
    fields = line.split()
    if len(fields) < 3:
        return False
    return fields[1] == "swap" or fields[2] == "swap"
