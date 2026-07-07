def main(ctx, params):
    # Extract arguments with defaults
    names = params.get("name")
    if isinstance(names, str):
        names = [names]
    elif names == None:
        names = None

    # Build docker CLI base args
    host = params.get("docker_host", "unix:///var/run/docker.sock")
    # Normalize host: docker CLI expects unix:// for local socket, tcp:// for remote
    # For TLS, the module would need cert/key paths; for now assume insecure local socket
    # This implementation assumes local docker daemon access via CLI (docker) for simplicity
    # since the original relies on Python docker API which is not available in Starlark.
    # We will use `docker images` and `docker inspect` via CLI.

    def docker_cmd(args, mutates=False):
        return ctx.run(["docker"] + args, mutates=mutates, ok_codes=[0])

    def inspect_image(image_ref):
        # image_ref can be name:tag or id
        res = docker_cmd(["inspect", "--type", "image", image_ref])
        if res.rc != 0:
            return None
        # Parse JSON manually (basic, no external deps)
        # Starlark has no JSON module; assume output is valid JSON and use simple parsing
        # For simplicity, return the raw JSON string and expect caller to handle structure
        # But Starlark cannot parse JSON without external help — we must skip deep inspection.
        # Instead, we will only gather image list if no names provided, or basic presence check.
        # This limitation is due to Starlark's lack of JSON parsing.
        # For compliance, we'll simulate a minimal fact: only return image ID list if no names,
        # or check presence for named images (return ID if exists).
        # Since the original returns detailed inspection, we cannot fully replicate without JSON parsing.
        # Workaround: fail if detailed inspection is needed and no external tool (e.g., jq) available.
        # However, Starlark has no jq; we assume jq is installed as common CLI tool for JSON.
        # If jq is missing, fail with clear message.
        # For this module, we try jq first — if not found, fail.
        res = ctx.run(["which", "jq"], mutates=False)
        if res.rc != 0:
            ctx.fail("jq is required to parse docker inspect output but not found. Install jq or use a Python-based implementation.")
        res = ctx.run(["docker", "inspect", "--type", "image", image_ref], mutates=False)
        if res.rc != 0:
            return None
        res_jq = ctx.run(["jq", "."], input_text=res.stdout, mutates=False)
        if res_jq.rc != 0:
            ctx.fail("Failed to parse docker inspect output with jq: " + res_jq.stderr)
        # jq returns a list; extract first item
        # Since jq output is a list, we use jq to get the first element
        res_jq_first = ctx.run(["jq", ".[0]"], input_text=res.stdout, mutates=False)
        if res_jq_first.rc != 0:
            ctx.fail("Failed to extract first image from jq output: " + res_jq_first.stderr)
        # Parse JSON-like manually (very basic, not robust)
        # Instead, we treat jq's output as a string and return it; caller must handle structure.
        # But the contract requires dict. Starlark cannot parse arbitrary JSON.
        # We'll return the raw string in a dict with key "raw", and expect the caller to use jq elsewhere.
        # This violates the contract — so we must fail with clear message if jq output cannot be parsed.
        # Since Starlark has no JSON, and jq output is structured, we must use jq to flatten to key-value pairs.
        # For minimal compliance, we return only image name and id as a dict.
        # Better: assume jq is available and use jq to produce key-value pairs.
        # Given constraints, we'll output a minimal set of facts using jq to extract key fields.
        res_keys = ctx.run(
            ["jq", "{Id, RepoTags, RepoDigests, Created, Size, VirtualSize, Config: .Config, Architecture, Os}"],
            input_text=res.stdout,
            mutates=False
        )
        if res_keys.rc != 0:
            ctx.fail("Failed to extract key fields with jq: " + res_keys.stderr)
        # This is still a dict-like string; we cannot parse it without a JSON parser.
        # Conclusion: In pure Starlark without external tools that produce JSON-compatible output,
        # this module cannot replicate the original's behavior. We fail with a clear message.
        ctx.fail("Docker image inspection in Starlark requires JSON parsing; jq output is not natively parseable. Use a Python-based implementation or ensure jq outputs flat key=value pairs (not JSON).")

    # Since detailed inspection is infeasible without JSON parsing, and the module is info-only,
    # we provide a simplified fallback: only return existence info for named images, or list IDs.
    # But this deviates from the contract. Instead, we assume the host has docker CLI and jq,
    # and we manually parse the jq output for a minimal set of fields (ID, RepoTags).
    # This is fragile but workable for common cases.

    # Alternative approach: skip jq and parse raw JSON with Starlark string methods — extremely limited.
    # Given the constraints, we choose to fail with a clear message if jq is missing or output too complex.

    # For this translation, we implement a minimal fallback:
    # - If no names: return list of image IDs (docker images -q)
    # - If names: for each name, check existence via docker images --format {{.ID}} | grep
    # But the original returns full inspection. Since Starlark cannot parse JSON, we cannot fulfill.

    # Final decision: fail with message to use a Python implementation, per Ansible best practice.

    ctx.fail("This module cannot be implemented in pure Starlark due to lack of JSON parsing. Use a Python-based docker_image_info implementation or request jq-based JSON extraction (which is not natively supported in Starlark).")
