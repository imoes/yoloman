def main(ctx, params):
    device = params["device"]
    source_url = params["source_url"]
    retries = params.get("retries", 5)

    # Construct the pipeline command
    pipeline = "set -o pipefail; curl -fsSL --retry %d --retry-all-errors '%s' | zstd -dc | partclone.restore -s - -o '%s'"
    cmd = pipeline % (retries, source_url, device)

    # Run the pipeline
    res = ctx.run(["sh", "-c", cmd], mutates=True)

    # Handle check mode (the mutating run is skipped in check mode)
    if res.skipped:
        return {
            "changed": True,
            "msg": "would restore image from %s to %s" % (source_url, device),
            "data": {"device": device, "source_url": source_url}
        }

    # Check for non-zero return code
    if res.rc != 0:
        fail("partclone restore failed: " + res.stderr)

    return {
        "changed": True,
        "msg": "restored image from %s to %s" % (source_url, device),
        "data": {"device": device, "source_url": source_url}
    }
