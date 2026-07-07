def main(ctx, params):
    name = params["name"]
    tag = params.get("tag", "latest")

    # Validate required parameters
    if not name:
        fail("name is required")

    # If name contains a tag (e.g., image:tag or image@digest), use it and ignore tag param
    if ":" in name or "@" in name:
        # Check for digest first
        if "@" in name:
            fail("Cannot push an image by digest")
        # Check for explicit tag
        colon_pos = name.rfind(":")
        if colon_pos > 0 and name.find("/", 0, colon_pos) == -1:
            name = name[:colon_pos]
            tag = name[colon_pos + 1:]

    # Validate tag
    if not tag or tag == "":
        fail('"" is not a valid docker tag!')

    # Check image exists locally
    res = ctx.run(["docker", "image", "inspect", name + ":" + tag], mutates=False)
    if res.rc != 0:
        fail("Cannot find image " + name + ":" + tag)

    # Determine registry for error reporting (simplified parsing)
    push_registry = "docker.io"
    push_repo = name
    if "/" in name:
        first_part = name.split("/", 1)[0]
        if "." in first_part or ":" in first_part or first_part == "localhost":
            push_registry = first_part
            push_repo = name[len(first_part)+1:]

    # Perform push (check_mode handled automatically by mutates=True)
    push_cmd = ["docker", "push", name + ":" + tag]
    res = ctx.run(push_cmd, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would push " + name + ":" + tag}

    if res.rc != 0:
        stderr_lower = res.stderr.lower()
        if "unauthorized" in stderr_lower or "authentication required" in stderr_lower:
            fail("Error pushing image " + push_registry + "/" + push_repo + ":" + tag + " - authentication required. Try logging into " + push_registry + " first.")
        elif "unauthorized" in stderr_lower:
            fail("Error pushing image " + push_registry + "/" + push_repo + ":" + tag + " - unauthorized. Does the repository exist?")
        else:
            fail("Error pushing image " + name + ":" + tag + ": " + res.stderr)

    # Detect if anything actually changed during push
    changed = "Pushing" in res.stdout or res.rc == 0

    return {
        "changed": changed,
        "msg": "Pushed image " + name + ":" + tag,
        "data": {
            "image": {
                "name": name,
                "tag": tag
            }
        }
    }
