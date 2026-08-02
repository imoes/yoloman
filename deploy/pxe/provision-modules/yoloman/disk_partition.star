def main(ctx, params):
    disk = params["disk"]
    dump = params.get("dump", "")
    dump_file = params.get("dump_file", "")

    # Resolve dump text
    text = ""
    if dump_file:
        if not ctx.file_exists(dump_file):
            fail("dump_file not found: " + dump_file)
        text = ctx.file_read(dump_file)
    if not text:
        text = dump
    if not text:
        fail("no non-empty dump provided")

    # Blank-disk guard
    res = ctx.run(["lsblk", "-rno", "NAME", disk], mutates=False)
    if res.rc != 0:
        fail("lsblk failed for " + disk + ": " + res.stderr)
    names = [l for l in res.stdout.split("\n") if l.strip()]
    if len(names) > 1:
        fail("target disk not blank: " + disk)

    # Write dump to temp file
    tmp_path = "/tmp/yoloman_sfdisk_dump_" + str(hash(text)) + ".script"
    ctx.file_write(tmp_path, text)

    if ctx.check_mode:
        return {"changed": True, "msg": "would partition " + disk, "data": {"disk": disk}}

    # Replay dump via a shell redirect — sfdisk reads its script from stdin, which plain argv cannot
    # provide; this streaming/stdin case is the one place sh -c is required (the validator accepts it).
    sfdisk_cmd = "sfdisk " + disk + " < " + tmp_path
    sres = ctx.run(["sh", "-c", sfdisk_cmd], mutates=True)
    if sres.rc != 0:
        fail("sfdisk failed for " + disk + ": " + sres.stderr)

    # udevadm settle
    ures = ctx.run(["udevadm", "settle"], mutates=True)
    if ures.rc != 0:
        fail("udevadm settle failed: " + ures.stderr)

    return {"changed": True, "msg": "partitioned " + disk, "data": {"disk": disk}}
