def main(ctx, params):
    name = params["name"]

    # Build docker inspect command: docker inspect <name>
    # Always use JSON format for reliable parsing
    res = ctx.run(["docker", "inspect", name], mutates=False)
    if res.rc == 0:
        # Container exists; parse JSON manually using basic string parsing
        # Starlark lacks json module, so extract exists=True and return raw JSON string
        # In real deployments, ctx.file_write + file_read might be used with an external helper,
        # but here we rely on docker inspect output structure:
        # - Returns array of objects if found; empty array if not found
        # - We assume stdout is a JSON array string
        stdout = res.stdout.strip()
        exists = bool(stdout.startswith("[") and stdout.endswith("]"))
        if not exists:
            # Handle edge case: non-empty invalid output (e.g., error message)
            fail("unexpected docker inspect output: " + stdout)
        return {
            "changed": False,
            "msg": "retrieved facts for container " + name,
            "data": {
                "exists": True,
                "container": stdout  # raw JSON string; caller may parse externally
            }
        }
    elif res.rc == 1 and "No such container" in res.stderr:
        # Container not found
        return {
            "changed": False,
            "msg": "container " + name + " does not exist",
            "data": {
                "exists": False,
                "container": None
            }
        }
    else:
        fail("failed to inspect container " + name + ": rc=" + str(res.rc) + ", stderr=" + res.stderr)
