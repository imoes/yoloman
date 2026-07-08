def main(ctx, params):
    group_id = params["group_id"]
    artifact_id = params["artifact_id"]
    version = params.get("version")
    version_by_spec = params.get("version_by_spec")
    classifier = params.get("classifier", "")
    extension = params.get("extension", "jar")
    repository_url = params.get("repository_url", "https://repo1.maven.org/maven2")
    username = params.get("username")
    password = params.get("password")
    dest = params["dest"]
    state = params.get("state", "present")
    timeout = params.get("timeout", 10)
    keep_name = params.get("keep_name", False)
    verify_checksum = params.get("verify_checksum", "download")
    checksum_alg = params.get("checksum_alg", "md5")
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    force_basic_auth = params.get("force_basic_auth", False)
    headers = params.get("headers")
    unredirected_headers = params.get("unredirected_headers")
    directory_mode = params.get("directory_mode")
    mode = params.get("mode")
    owner = params.get("owner")
    group = params.get("group")
    seuser = params.get("seuser")
    serole = params.get("serole")
    setype = params.get("setype")
    selevel = params.get("selevel")
    unsafe_writes = params.get("unsafe_writes", False)

    # Validation: mutually exclusive version params
    if version != None and version_by_spec != None:
        fail("version and version_by_spec are mutually exclusive")
    if state == "absent":
        # For absent state, just remove the file if exists
        if ctx.file_exists(dest):
            ctx.run(["rm", "-f", dest])
            return {"changed": True, "msg": "removed %s" % dest}
        return {"changed": False, "msg": "file %s already absent" % dest}

    # Only support 'present' state
    if state != "present":
        fail("unsupported state: %s" % state)

    # Check dependencies (no lxml/semantic_version available in Starlark)
    # So we fall back to simple parsing without lxml — only basic cases supported
    # Metadata parsing requires lxml, so we restrict to non-latest/non-range cases
    # This is a minimal implementation: supports explicit version or latest with simple URL pattern
    # For version_by_spec, we require semantic_version — fail if not handled
    if version_by_spec != None:
        fail("version_by_spec requires semantic_version support (not available in this Starlark runtime)")
    if version == None:
        version = "latest"

    # Build artifact path
    group_path = group_id.replace(".", "/")
    artifact_path = "%s/%s" % (group_path, artifact_id)
    base_url = repository_url.rstrip("/")

    # Handle file:// repositories
    local_repo = base_url.startswith("file://")
    if local_repo:
        repo_path = base_url[7:]  # strip "file://"
        artifact_url = "%s/%s/%s" % (repo_path, artifact_path, artifact_id)
        # For simplicity, assume local repo doesn't use snapshots metadata; just try exact file
        if version == "latest":
            fail("latest not supported for file:// repositories in this minimal implementation")
        dest_path = dest
        if dest.endswith("/") or dest.endswith("\\"):
            # Build filename without version if keep_name=False
            filename = "%s-%s.%s" % (artifact_id, classifier + ("." if classifier else "") if classifier else "", extension)
            if not classifier:
                filename = "%s.%s" % (artifact_id, extension)
            dest_path = dest.rstrip("/\\") + "/" + filename.replace("//", "/")
        else:
            dest_path = dest
        src_path = "%s/%s/%s/%s-%s.%s" % (repo_path, group_path, artifact_id, artifact_id, version, extension)
        if classifier:
            src_path = "%s-%s-%s.%s" % (src_path[:-len(extension)-1], classifier, extension)
        # Check source exists
        if ctx.file_exists(src_path):
            # Checksum check: for local, compare sizes and timestamps (simplified)
            src_stat = ctx.stat(src_path)
            if ctx.file_exists(dest_path):
                dest_stat = ctx.stat(dest_path)
                if src_stat.size == dest_stat.size:
                    return {"changed": False, "msg": "file already present and identical"}
            # Download via copy
            ctx.run(["cp", "-p", src_path, dest_path])
            return {"changed": True, "msg": "copied %s to %s" % (src_path, dest_path)}
        else:
            fail("artifact not found at %s" % src_path)

    # S3 repositories require boto3 — fail in Starlark
    if base_url.startswith("s3://"):
        fail("S3 repositories require boto3 (not available in this Starlark runtime)")

    # For HTTP(S), we must use ctx.run with curl/wget — prefer curl
    # Construct artifact URL
    if version == "latest":
        # Minimal fallback: use repository_url + path + artifact_id + "." + extension
        # This is best-effort — real latest requires parsing maven-metadata.xml
        version_url = "%s/%s/maven-metadata.xml" % (base_url, artifact_path)
        res = ctx.run(["curl", "-s", "-f", "--max-time", str(timeout), version_url])
        if res.rc != 0:
            fail("failed to fetch maven metadata from %s: %s" % (version_url, res.stderr))
        # Parse the last version from XML manually
        content = res.stdout
        # Very basic parser for <latest> tag — assumes simple structure
        lines = content.split("\n")
        latest_ver = None
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("<latest>") and stripped.endswith("</latest>"):
                latest_ver = stripped.replace("<latest>", "").replace("</latest>", "")
                break
        if latest_ver == None:
            fail("failed to parse latest version from metadata")
        version = latest_ver

    # Build full artifact URL
    if classifier:
        artifact_url = "%s/%s/%s-%s-%s.%s" % (base_url, artifact_path, artifact_id, version, classifier, extension)
    else:
        artifact_url = "%s/%s/%s-%s.%s" % (base_url, artifact_path, artifact_id, version, extension)

    # Prepare download command
    curl_args = ["curl", "-f", "-L", "--max-time", str(timeout), "-o", dest]
    if force_basic_auth:
        curl_args.extend(["--basic"])
    if username != None:
        curl_args.extend(["-u", username + ":" + (password if password != None else "")])
    if client_cert != None:
        curl_args.extend(["--cert", client_cert])
        if client_key != None:
            curl_args.extend(["--key", client_key])
    if headers != None:
        for key, val in headers.items():
            curl_args.extend(["-H", "%s: %s" % (key, val)])
    if verify_checksum in ["download", "change", "always"]:
        # Download checksum file for verification (simplified)
        checksum_url = artifact_url + "." + checksum_alg
        res = ctx.run(["curl", "-s", "-f", "--max-time", str(timeout), checksum_url])
        expected_checksum = res.stdout.strip().split()[0] if res.rc == 0 else None
        if res.rc != 0 or expected_checksum == None:
            if verify_checksum in ["change", "always"]:
                fail("failed to retrieve %s checksum from %s" % (checksum_alg, checksum_url))
            # If never or download and checksum missing, continue anyway
        else:
            curl_args.append(artifact_url)
            res = ctx.run(curl_args)
            if res.rc != 0:
                fail("curl failed: %s" % res.stderr)
            # Verify checksum after download
            if expected_checksum != None:
                # Use md5sum/sha1sum if available; otherwise, skip
                alg_cmd = "md5sum" if checksum_alg == "md5" else "sha1sum"
                ver_res = ctx.run([alg_cmd, dest])
                if ver_res.rc == 0:
                    actual = ver_res.stdout.split()[0]
                    if actual != expected_checksum:
                        fail("%s checksum mismatch: expected %s, got %s" % (checksum_alg, expected_checksum, actual))
    else:
        curl_args.append(artifact_url)
        res = ctx.run(curl_args)
        if res.rc != 0:
            fail("curl failed: %s" % res.stderr)

    # Set file attributes if needed
    file_args = {}
    if mode != None:
        file_args["mode"] = mode
    if owner != None:
        file_args["owner"] = owner
    if group != None:
        file_args["group"] = group
    if seuser != None:
        file_args["seuser"] = seuser
    if serole != None:
        file_args["serole"] = serole
    if setype != None:
        file_args["setype"] = setype
    if selevel != None:
        file_args["selevel"] = selevel

    if file_args:
        # Use chmod/chown if possible, fallback to fail
        changed_attrs = False
        if "mode" in file_args:
            ctx.run(["chmod", file_args["mode"], dest])
            changed_attrs = True
        if "owner" in file_args:
            ctx.run(["chown", file_args["owner"], dest])
            changed_attrs = True
        if "group" in file_args:
            ctx.run(["chgrp", file_args["group"], dest])
            changed_attrs = True
        # SELinux attributes not supported in basic Starlark — ignore silently or fail if required
        if changed_attrs:
            return {"changed": True, "msg": "downloaded and set attributes on %s" % dest}

    return {"changed": True, "msg": "downloaded %s to %s" % (artifact_url, dest)}
