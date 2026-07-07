def main(ctx, params):
    # Required parameters
    name = params["name"]
    tag = params.get("tag", "latest")
    platform_val = params.get("platform")
    pull_mode = params.get("pull", "always")

    # Fail on image ID (not supported)
    if name.startswith("sha256:"):
        fail("Cannot pull an image by ID")
    # Basic tag validation (non-empty, no spaces)
    if not tag or " " in tag:
        fail('"{0}" is not a valid docker tag!'.format(tag if tag else "empty"))

    # Handle tag/digest in name: extract repo and tag/digest if present
    # Look for ':' or '@' after the first '/' (to avoid port confusion)
    # Simple heuristic: split on ':' or '@' only after the last '/' or if no '/'
    repo, repo_tag = name, None
    last_slash = name.rfind("/")
    for i, c in enumerate(name):
        if c in [":", "@"] and (last_slash < 0 or i > last_slash):
            if c == ":":
                repo, repo_tag = name[:i], name[i + 1:]
            elif c == "@":
                repo, repo_tag = name[:i], name[i + 1:]
            break

    if repo_tag != None:
        name = repo
        tag = repo_tag

    # Determine docker_host and build command
    docker_host = params.get("docker_host", "unix:///var/run/docker.sock")
    # Auto-detect TLS/HTTPS: if tcp:// and tls/validate_certs, switch to https://
    host = docker_host
    if docker_host.startswith("tcp://"):
        if params.get("tls", False) or params.get("validate_certs", False):
            host = "https://" + docker_host[6:]
        else:
            host = "http://" + docker_host[6:]

    # Build docker CLI args
    base = ["docker", "-H", host]

    # TLS/CA/client cert options
    if params.get("validate_certs", False):
        base += ["--tls"]
        if params.get("ca_path"):
            base += ["--tlscacert", params["ca_path"]]
        if params.get("client_cert"):
            base += ["--tlscert", params["client_cert"]]
        if params.get("client_key"):
            base += ["--tlskey", params["client_key"]]
    elif params.get("tls", False):
        base += ["--tls"]
        # skip verify if only tls=True and not validate_certs (per doc)
    else:
        base += ["--tls=false"]

    # Platform (optional)
    if platform_val:
        base += ["--platform", platform_val]

    # Pull command
    cmd = base + ["pull", name + ":" + tag]

    # Probe: check if image exists (with exact tag)
    probe_cmd = base + ["images", "--format", "{{.Repository}}:{{.Tag}}"]
    res = ctx.run(probe_cmd, mutates=False)
    if res.rc != 0:
        fail("Failed to list images: " + res.stderr)
    existing = set(res.stdout.splitlines()) if res.stdout.strip() else set()
    image_exists = (name + ":" + tag) in existing

    # Pull logic per 'pull' mode
    if pull_mode == "not_present" and image_exists:
        # If platform provided, check platform match
        if platform_val:
            # Inspect image to get its platform
            inspect_cmd = base + ["inspect", "--format", "{{.Os}}/{{.Architecture}}{{if .Variant}}/{{.Variant}}{{end}}", name + ":" + tag]
            ins_res = ctx.run(inspect_cmd, mutates=False)
            if ins_res.rc != 0:
                fail("Failed to inspect image: " + ins_res.stderr)
            img_platform = ins_res.stdout.strip() if ins_res.stdout.strip() else ""
            # Simple daemon platform guess (use facts as fallback)
            facts = ctx.facts()
            os_type = facts.get("os_family", "linux")
            arch = facts.get("architecture", "amd64")
            # Normalize to "os/arch[variant]" format loosely
            daemon_platform = os_type + "/" + arch
            if img_platform.lower() == daemon_platform.lower():
                return {"changed": False, "msg": "Image already exists and platform matches"}
        else:
            return {"changed": False, "msg": "Image already exists"}

    # Prepare result
    results = {
        "changed": False,
        "msg": "",
        "image": {}
    }

    if ctx.check_mode:
        results["changed"] = True
        results["msg"] = "Would pull {0}:{1}".format(name, tag)
        # Return dummy image ID for diff (per original behavior)
        results["image"] = {"Id": "unknown"}
        return results

    # Actual pull
    pull_res = ctx.run(cmd, mutates=True)
    if pull_res.skipped:
        results["changed"] = True
        results["msg"] = "Would pull {0}:{1}".format(name, tag)
        results["image"] = {"Id": "unknown"}
        return results

    if pull_res.rc != 0:
        fail("Failed to pull {0}:{1}: {2}".format(name, tag, pull_res.stderr))

    # After pull, get image ID
    inspect_cmd = base + ["inspect", "--format", "{{.Id}}", name + ":" + tag]
    ins_res = ctx.run(inspect_cmd, mutates=False)
    if ins_res.rc != 0:
        fail("Failed to inspect pulled image: " + ins_res.stderr)
    image_id = ins_res.stdout.strip() if ins_res.stdout.strip() else ""

    results["changed"] = True
    results["msg"] = "Pulled image {0}:{1}".format(name, tag)
    results["image"] = {"Id": image_id}

    return results
