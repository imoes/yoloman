# yoloman.disk_partition — write a partition table onto a target disk from an sfdisk dump.
#
# A PROVISIONING-ONLY module (baked into the PE, not the builtin agent): the restore reproduces
# the source's exact partition layout by replaying its `sfdisk --dump` on the blank target. This
# is NOT declarative partitioning (community.general.parted) — it restores a verbatim dump, so the
# partition types/UUIDs/order match the captured image byte-for-byte. Runs in the PE against the
# raw disk (no chroot). Contract: {changed, msg, data}.
#
# Refuses a non-blank disk here too (defence in depth — restore_steps already guards): replaying a
# table over existing partitions would corrupt real data.

def main(ctx, params):
    disk = params.get("disk")
    dump = params.get("dump")
    dump_file = params.get("dump_file")
    if not disk:
        fail("disk is required (e.g. /dev/sda)")
    # The dump can be passed inline (dump) or read from a file the PE already wrote (dump_file) —
    # pe-init.sh writes the checkin's sfdisk_script to /tmp/target.sfdisk, so the restore passes that.
    if dump_file:
        if not ctx.file_exists(dump_file):
            fail("dump_file %s does not exist" % dump_file)
        dump = ctx.file_read(dump_file)
    if not dump or not dump.strip():
        fail("dump (or dump_file) is required — the sfdisk --dump text to replay")

    # Blank-disk guard: no existing partitions.
    children = ctx.run(["sh", "-c", "lsblk -rno NAME %s | tail -n +2" % _q(disk)], mutates=False)
    if children.rc == 0 and children.stdout.strip():
        fail("target disk %s is not blank (found partitions) — a deploy target must be empty" % disk)

    # Replay the dump. sfdisk reads the layout from stdin; write it to a file first so the module
    # does not depend on shell here-strings.
    ctx.file_write("/tmp/.yoloman-target.sfdisk", dump, mode="0600")
    res = ctx.run(["sh", "-c", "sfdisk %s < /tmp/.yoloman-target.sfdisk" % _q(disk)], mutates=True)
    if res.rc != 0:
        fail("sfdisk failed on %s: %s" % (disk, res.stderr))
    # Let the kernel create the new partition device nodes before anything uses them.
    ctx.run(["udevadm", "settle"], mutates=True)
    return {
        "changed": True,
        "msg": "wrote partition table to %s from sfdisk dump" % disk,
        "data": {"disk": disk},
    }


def _q(s):
    # minimal shell-quote (the paths here are device names / our own temp file)
    return "'" + s.replace("'", "'\\''") + "'"
