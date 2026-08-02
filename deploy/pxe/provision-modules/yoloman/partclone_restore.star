# yoloman.partclone_restore — stream a captured filesystem image onto a target device.
#
# A PROVISIONING-ONLY module (baked into the PE, not the builtin agent). The pipeline is
# `curl -fsSL --retry N <url> | zstd -dc | partclone.restore -s - -o <device>`:
#   - curl -f fails loudly on a bad HTTP status instead of writing an error page onto the disk
#     (which would look like a successful restore but be unbootable); --retry survives a blip.
#   - partclone.restore (not dd, not a per-fs binary): the image holds ONLY used blocks and its own
#     header, so partclone picks the right handler and writes just the used blocks. dd would splatter
#     the metadata stream onto the disk as data.
# Runs in the PE against the target device (no chroot). Contract: {changed, msg, data}.

def main(ctx, params):
    device = params.get("device")
    url = params.get("source_url")
    if not device:
        fail("device is required (e.g. /dev/sda2 or /dev/mapper/vg-root)")
    if not url:
        fail("source_url is required (the image URL to restore)")
    retries = params.get("retries", 5)

    pipeline = "curl -fsSL --retry %d --retry-all-errors %s | zstd -dc | partclone.restore -s - -o %s" % (
        int(retries), _q(url), _q(device),
    )
    # pipefail so a failure in curl/zstd (not just partclone) fails the step.
    res = ctx.run(["sh", "-c", "set -o pipefail; " + pipeline], mutates=True)
    if res.rc != 0:
        fail("partclone restore to %s failed: %s" % (device, res.stderr))
    return {
        "changed": True,
        "msg": "restored image to %s" % device,
        "data": {"device": device, "source_url": url},
    }


def _q(s):
    return "'" + s.replace("'", "'\\''") + "'"
