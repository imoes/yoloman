def main(ctx, params):
    state = params["state"]
    pool = params.get("pool", "zones")
    imgtype = params.get("type", "imgapi")
    uuid = params.get("uuid")
    source = params.get("source")
    force = params.get("force", False)

    # Validate UUID if provided and not '*'
    if uuid and uuid != "*":
        # Use string matching for UUID pattern instead of regex import
        valid_uuid = True
        if len(uuid) != 36:
            valid_uuid = False
        else:
            for i, c in enumerate(uuid):
                if i in [8, 13, 18, 23]:
                    if c != '-':
                        valid_uuid = False
                        break
                else:
                    if not (c in '0123456789abcdefABCDEF'):
                        valid_uuid = False
                        break
        if not valid_uuid:
            fail("Provided value for uuid option is not a valid UUID.")

    # Check if imgadm is available
    res = ctx.run(["which", "imgadm"])
    if res.rc != 0:
        fail("imgadm command not found")

    # Helper to extract error message from stderr
    def errmsg(stderr):
        # Simple heuristic to extract error message
        # Expected format: "imgadm ...: error (xxx): <message>: ..."
        parts = stderr.split(": error (")
        if len(parts) >= 2:
            subparts = parts[1].split("): ")
            if len(subparts) >= 2:
                return subparts[1].strip()
        return "Unexpected failure"

    changed = False

    # Handle sources (when source is provided)
    if source:
        if state in ["present", "imported", "updated"]:
            cmd = ["imgadm", "-a", source, "-t", imgtype]
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would add source " + source, "source": source}
            if res.rc != 0:
                fail("Failed to add source: " + errmsg(res.stderr))

            if "no change" in res.stdout:
                changed = False
            elif "Added" in res.stdout and imgtype in res.stdout and source in res.stdout:
                changed = True
        else:  # absent/deleted
            cmd = ["imgadm", "sources", "-d", source]
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would delete source " + source, "source": source}
            if res.rc != 0:
                fail("Failed to remove source: " + errmsg(res.stderr))

            if "no change" in res.stdout:
                changed = False
            elif "Deleted" in res.stdout and 'image source' in res.stdout:
                changed = True

        return {"changed": changed, "msg": "source " + source + " updated", "source": source}

    # Handle images (uuid provided)
    if state == "updated":
        if uuid == "*":
            cmd = ["imgadm", "update"]
        else:
            cmd = ["imgadm", "update", uuid]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would update images", "uuid": uuid}
        if res.rc != 0:
            fail("Failed to update images: " + errmsg(res.stderr))
        # imgadm has no clear feedback on whether changes occurred; assume changed
        changed = True
        return {"changed": changed, "msg": "images updated", "uuid": uuid}

    # Validate uuid is provided (except for vacuumed which allows uuid='*')
    if not uuid and state != "vacuumed":
        fail("uuid is required for state: " + state)

    # Handle vacuumed
    if state == "vacuumed":
        cmd = ["imgadm", "vacuum", "-f"]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would vacuum images", "uuid": uuid}
        if res.rc != 0:
            fail("Failed to vacuum images: " + errmsg(res.stderr))
        changed = bool(res.stdout.strip())  # stdout empty = no changes
        return {"changed": changed, "msg": "images vacuumed", "uuid": uuid}

    # Handle present/imported
    if state in ["present", "imported"]:
        cmd = ["imgadm", "import", "-P", pool, "-q", uuid]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would import image " + uuid, "uuid": uuid}
        if res.rc != 0:
            fail("Failed to import image: " + errmsg(res.stderr))
        # Parse output to determine if changed
        if "already installed" in res.stdout:
            changed = False
        elif "ActiveImageNotFound" in res.stderr:
            changed = False
        elif "Imported image" in res.stdout and uuid in res.stdout:
            changed = True
        else:
            changed = True  # Default to changed if imported successfully
        return {"changed": changed, "msg": "image " + uuid + " imported", "uuid": uuid}

    # Handle absent/deleted
    if state in ["absent", "deleted"]:
        cmd = ["imgadm", "delete", "-P", pool, uuid]
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete image " + uuid, "uuid": uuid}
        # Check for ImageNotInstalled
        if "ImageNotInstalled" in res.stderr:
            changed = False
        elif "Deleted image" in res.stdout and uuid in res.stdout:
            changed = True
        else:
            changed = False  # Default unchanged if not explicitly deleted
        return {"changed": changed, "msg": "image " + uuid + " deleted", "uuid": uuid}

    fail("Unsupported state: " + state)
