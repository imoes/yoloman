def main(ctx, params):
    domain = params["domain"]
    permissive = params["permissive"]
    no_reload = params.get("no_reload", False)
    store = params.get("store", "")

    # Check for SELinux availability by trying to run semanage
    res = ctx.run(["which", "semanage"], mutates=False)
    if res.rc != 0:
        fail("semanage not found; policycoreutils-python is required")

    # Get current permissive domains using semanage
    argv = ["semanage", "permissive", "-l"]
    if store:
        argv.extend(["-S", store])
    res = ctx.run(argv, mutates=False)
    if res.rc != 0:
        fail("failed to list permissive domains: " + res.stderr)
    
    current_permissive = []
    for line in res.stdout.split("\n"):
        stripped = line.strip()
        if stripped and not stripped.startswith("Permissive"):
            # Extract domain name from lines like "httpd_t" or "  httpd_t"
            current_permissive.append(stripped)

    # Determine if change is needed
    in_list = domain in current_permissive
    should_be_in_list = permissive

    if in_list == should_be_in_list:
        return {"changed": False, "msg": "domain %s already %s permissive" % (domain, "in" if permissive else "not in")}

    # Check mode: predict change without modifying
    if ctx.check_mode:
        return {"changed": True, "msg": "would set domain %s %s permissive" % (domain, "to" if permissive else "not")}

    # Apply change using semanage
    if permissive:
        argv = ["semanage", "permissive", "-a", domain]
    else:
        argv = ["semanage", "permissive", "-d", domain]
    if store:
        argv.extend(["-S", store])
    
    res = ctx.run(argv, mutates=True)
    if res.rc != 0:
        fail("failed to %s permissive domain %s: %s" % ("add" if permissive else "delete", domain, res.stderr))

    # Reload policy unless no_reload is set
    if not no_reload:
        reload_argv = ["semodule", "-B"]
        if store:
            reload_argv.extend(["-s", store])
        reload_res = ctx.run(reload_argv, mutates=True)
        if reload_res.rc != 0:
            fail("failed to reload SELinux policy: " + reload_res.stderr)

    return {"changed": True, "msg": "set domain %s %s permissive" % (domain, "to" if permissive else "not")}
