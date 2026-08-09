def main(ctx, params):
    # Extract params
    timeout = params.get("timeout", "30m")
    puppetmaster = params.get("puppetmaster")
    modulepath = params.get("modulepath")
    manifest = params.get("manifest")
    confdir = params.get("confdir")
    noop = params.get("noop")
    logdest = params.get("logdest", "stdout")
    show_diff = params.get("show_diff", False)
    facts = params.get("facts")
    facter_basename = params.get("facter_basename", "ansible")
    environment = params.get("environment")
    certname = params.get("certname")
    tags = params.get("tags")
    skip_tags = params.get("skip_tags")
    execute = params.get("execute")
    summarize = params.get("summarize", False)
    debug = params.get("debug", False)
    verbose = params.get("verbose", False)
    use_srv_records = params.get("use_srv_records")

    # Validate mutually exclusive: (puppetmaster, manifest), (puppetmaster, execute), (puppetmaster, modulepath)
    if puppetmaster != None:
        if manifest != None or execute != None or modulepath != None:
            fail("mutually_exclusive: puppetmaster cannot be used with manifest, execute, or modulepath")

    # Validate manifest exists if provided
    if manifest != None and not ctx.file_exists(manifest):
        fail("Manifest file %s not found." % manifest)

    # Build base command
    cmd = ["puppet"]
    if manifest != None or execute != None:
        cmd.append("apply")
    else:
        cmd.append("agent")

    # Add timeout
    cmd.extend(["--timeout", timeout])

    # Conditional arguments
    if puppetmaster != None:
        cmd.extend(["--server", puppetmaster])
    if modulepath != None:
        cmd.extend(["--modulepath", modulepath])
    if manifest != None:
        cmd.extend(["--file", manifest])
    if confdir != None:
        cmd.extend(["--confdir", confdir])
    if noop != None:
        cmd.append("--noop" if noop else "--no-noop")
    if environment != None:
        cmd.extend(["--environment", environment])
    if certname != None:
        cmd.extend(["--certname", certname])
    if logdest != None and logdest != "stdout":
        if logdest == "all":
            cmd.extend(["--logdest", "console", "--logdest", "syslog"])
        else:
            cmd.extend(["--logdest", logdest])
    if show_diff:
        cmd.append("--show-diff")
    if tags != None:
        cmd.append("--tags")
        cmd.append(",".join(tags))
    if skip_tags != None:
        cmd.append("--skip_tags")
        cmd.append(",".join(skip_tags))
    if summarize:
        cmd.append("--summarize")
    if debug:
        cmd.append("--debug")
    if verbose:
        cmd.append("--verbose")
    if use_srv_records != None:
        cmd.append("--use_srv_records" if use_srv_records else "--no-use_srv_records")

    # Handle facts (only if present and not in check_mode)
    if facts != None and not ctx.check_mode:
        # Try /var/lib/facter/facts.d first (common), then fallback to /var/lib/puppet/facts
        facts_dir = "/var/lib/facter/facts.d"
        if not ctx.file_exists(facts_dir):
            facts_dir = "/var/lib/puppet/facts"
            if not ctx.file_exists(facts_dir):
                fail("Facts directory not found. Ensure /var/lib/facter/facts.d or /var/lib/puppet/facts exists.")

        # Write facts JSON file
        facts_path = facts_dir + "/" + facter_basename + ".json"
        facts_content = _dict_to_json(facts)
        ctx.file_write(facts_path, facts_content)

    # Add execute/manifest for apply mode
    if execute != None:
        cmd.extend(["--execute", execute])
    elif manifest != None:
        cmd.append(manifest)

    # Run puppet
    res = ctx.run(cmd, mutates=True)

    if res.skipped:
        return {"changed": True, "msg": "would run puppet"}

    # Handle return codes
    rc = res.rc
    stdout = res.stdout if res.stdout != None else ""
    stderr = res.stderr if res.stderr != None else ""

    if rc == 0:
        return {"changed": False, "stdout": stdout, "stderr": stderr}
    elif rc == 1:
        disabled = "administratively disabled" in stdout
        msg = "puppet is disabled" if disabled else "puppet did not run"
        return {"rc": rc, "disabled": disabled, "msg": msg, "stdout": stdout, "stderr": stderr}
    elif rc == 2:
        # success with changes
        return {"changed": True, "stdout": stdout, "stderr": stderr}
    elif rc == 124:
        return {"rc": rc, "msg": "puppet timed out", "stdout": stdout, "stderr": stderr}
    else:
        fail("puppet failed with return code: %d" % rc)


def _dict_to_json(d):
    # Simple JSON serializer for basic types (no recursion beyond 1 level depth, handles common cases)
    parts = []
    for k in sorted(d.keys()):
        v = d.get(k)
        if type(v) == "string":
            escaped = v.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
            parts.append("\"%s\": \"%s\"" % (k, escaped))
        elif type(v) == "bool":
            parts.append("\"%s\": %s" % (k, "true" if v else "false"))
        elif type(v) == "int":
            parts.append("\"%s\": %d" % (k, v))
        elif v == None:
            parts.append("\"%s\": null" % k)
        elif type(v) == "dict":
            parts.append("\"%s\": {%s}" % (k, _dict_to_json(v)))
        elif type(v) == "list":
            items = []
            for item in v:
                if type(item) == "string":
                    escaped = item.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
                    items.append("\"%s\"" % escaped)
                elif type(item) == "bool":
                    items.append("true" if item else "false")
                elif type(item) == "int":
                    items.append(str(item))
                elif item == None:
                    items.append("null")
                else:
                    items.append("\"%s\"" % str(item))
            parts.append("\"%s\": [%s]" % (k, ", ".join(items)))
        else:
            parts.append("\"%s\": \"%s\"" % (k, str(v)))
    return "{" + ", ".join(parts) + "}"
