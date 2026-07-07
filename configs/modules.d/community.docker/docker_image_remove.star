def main(ctx, params):
    name = params["name"]
    tag = params.get("tag", "latest")
    force = params.get("force", False)
    prune = params.get("prune", True)

    # Construct full image spec: prefer tag from name if present
    full_name = name
    if ":" in name and not name.endswith(":") and not name.startswith(":"):
        # name already contains a tag; extract it
        parts = name.rsplit(":", 1)
        # naive check to avoid false positives with registry host:port
        if len(parts) == 2 and not parts[0].endswith("/") and not parts[0].endswith(":"):
            full_name = parts[0]
            tag = parts[1]

    # Probe current state: list images and find a match by name:tag or id
    res = ctx.run(["docker", "images", "--format", "{{.Repository}}:{{.Tag}}|{{.ID}}"], mutates=False)
    if res.rc != 0:
        fail("failed to list docker images: " + res.stderr)

    images = []
    for line in res.stdout.strip().splitlines():
        if not line.strip():
            continue
        if "|" in line:
            ref, img_id = line.rsplit("|", 1)
            images.append({"ref": ref.strip(), "id": img_id.strip()})
        else:
            images.append({"ref": line.strip(), "id": ""})

    # Find matching image: prefer exact name:tag match, fallback to ID match
    image_id = None
    image_ref = None
    if ":" in name and tag == "latest" and not name.endswith(":"):
        # name may be image:tag already; attempt to find exact match
        for img in images:
            if img["ref"] == full_name:
                image_id = img["id"]
                image_ref = full_name
                break
    else:
        # Check exact name:tag first
        target = full_name + ":" + tag
        for img in images:
            if img["ref"] == target:
                image_id = img["id"]
                image_ref = target
                break

    # If no name:tag match, try ID lookup
    if image_id == None:
        # Try to find by ID directly
        res = ctx.run(["docker", "images", "--no-trunc", "--format", "{{.ID}}"], mutates=False)
        if res.rc == 0:
            for line in res.stdout.strip().splitlines():
                if line.strip() == full_name or line.strip() == name:
                    image_id = line.strip()
                    # Re-fetch ref for that ID
                    res2 = ctx.run(["docker", "images", "--no-trunc", "--format", "{{.Repository}}:{{.Tag}}|{{.ID}}"], mutates=False)
                    if res2.rc == 0:
                        for l in res2.stdout.strip().splitlines():
                            if "|" in l and l.split("|")[1].strip() == image_id:
                                image_ref = l.split("|")[0].strip()
                                break

    # No image found → idempotent
    if image_id == None or image_ref == None:
        return {"changed": False, "msg": "image not found", "image": {}, "deleted": [], "untagged": []}

    # Check mode: predict change without mutating
    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "would remove image " + image_ref,
            "image": {"Id": image_id},
            "deleted": [],
            "untagged": [image_ref],
        }

    # Remove image via docker rmi
    args = ["docker", "rmi"]
    if force:
        args.append("--force")
    if not prune:
        args.append("--no-prune")
    args.append(image_id)

    res = ctx.run(args, mutates=True)
    if res.rc != 0:
        fail("failed to remove image " + image_ref + ": " + res.stderr)

    # Parse output to extract untagged and deleted digests
    untagged = []
    deleted = []
    # docker rmi output is human-readable; attempt to parse common patterns
    output = res.stdout
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("Untagged: "):
            untagged.append(line[len("Untagged: "):])
        elif line.startswith("Deleted: ") or line.startswith("Deleted: ID: "):
            val = line.split(": ", 1)[-1].strip() if ": " in line else line[len("Deleted: "):].strip()
            deleted.append(val)

    return {
        "changed": True,
        "msg": "removed image " + image_ref,
        "image": {"Id": image_id},
        "deleted": sorted(deleted),
        "untagged": sorted(untagged),
    }
