def main(ctx, params):
    # Constants
    DNF_BIN = "/usr/bin/dnf"
    VERSIONLOCK_CONF = "/etc/dnf/plugins/versionlock.conf"
    
    # Parameters
    name = params.get("name", [])
    raw = params.get("raw", False)
    state = params.get("state", "present")
    
    # Pre-requisites checks
    if not ctx.file_exists(DNF_BIN):
        fail(DNF_BIN + " was not found")
    if not ctx.file_exists(VERSIONLOCK_CONF):
        fail("plugin versionlock is required")
    
    # Check incompatible options
    if state == "clean" and name:
        fail("clean state is incompatible with a name list")
    if state != "clean" and not name:
        fail("name list is required for " + state + " state")
    
    # Get current locklist (read-only, runs even in check_mode)
    res = ctx.run([DNF_BIN, "-q", "versionlock", "list"], mutates=False)
    locklist_pre = res.stdout.strip().split() if res.stdout.strip() else []
    
    specs_toadd = []
    specs_todelete = []
    
    # Helper function: run dnf versionlock command with patterns
    def run_versionlock(cmd, patterns=None, raw_flag=False):
        args = [DNF_BIN, "-q", "versionlock", cmd]
        if raw_flag:
            args.append("--raw")
        if patterns:
            for p in patterns:
                args.append(p)
        res = ctx.run(args, mutates=True)
        return res
    
    # Handle states
    if state in ["present", "excluded"]:
        if raw:
            # Add raw patterns as specs to add
            for p in name:
                expected = p if state == "present" else "!" + p
                if expected not in locklist_pre:
                    specs_toadd.append(p)
        else:
            # Get available packages using repoquery
            repoquery_args = [DNF_BIN, "-q", "repoquery"] + name
            res = ctx.run(repoquery_args, mutates=False)
            available_packages = res.stdout.strip().split() if res.stdout.strip() else []
            
            # Get installed packages
            repoquery_installed_args = [DNF_BIN, "-q", "repoquery", "--installed"] + name
            res = ctx.run(repoquery_installed_args, mutates=False)
            installed_packages = res.stdout.strip().split() if res.stdout.strip() else []
            
            # Build map: name -> set of evrs
            packages_map_name_evrs = {}
            for pkg in available_packages + installed_packages:
                parts = pkg.rsplit("-", 2)
                if len(parts) >= 3:
                    name_part = "-".join(parts[:-2])
                    evr = parts[-2] + "-" + parts[-1]
                    if name_part not in packages_map_name_evrs:
                        packages_map_name_evrs[name_part] = set()
                    packages_map_name_evrs[name_part].add(evr)
            
            # Generate locklist entries to add
            for pkg_name in packages_map_name_evrs:
                for evr in packages_map_name_evrs[pkg_name]:
                    locklist_entry = pkg_name + "-" + evr + ".*"
                    expected = locklist_entry if state == "present" else "!" + locklist_entry
                    if expected not in locklist_pre:
                        # Extract pattern for command: use original name spec
                        for spec in name:
                            # Check if this spec matches the package
                            if pkg_name.startswith(spec.replace("*", "")) or fnmatch_fn(spec, pkg_name):
                                if spec not in specs_toadd:
                                    specs_toadd.append(spec)
                                break
    
    elif state == "absent":
        if raw:
            for p in name:
                if p in locklist_pre:
                    specs_todelete.append(p)
        else:
            # Match locklist entries to delete patterns
            for pattern in name:
                for entry in locklist_pre:
                    if fnmatch_fn(entry.lstrip('!'), pattern):
                        if pattern not in specs_todelete:
                            specs_todelete.append(pattern)
    
    elif state == "clean":
        specs_todelete = locklist_pre[:]
    
    # Compute changed status
    changed = bool(specs_toadd or specs_todelete)
    
    # Execute changes (only if not check_mode)
    if changed and not ctx.check_mode:
        if state in ["present", "excluded"] and specs_toadd:
            cmd = "add" if state == "present" else "exclude"
            res = run_versionlock(cmd, patterns=specs_toadd, raw_flag=raw)
            if res.rc != 0:
                fail("failed to " + cmd + " versionlock: " + res.stderr)
        
        elif state == "absent" and specs_todelete:
            res = run_versionlock("delete", patterns=specs_todelete, raw_flag=raw)
            if res.rc != 0:
                fail("failed to delete versionlock: " + res.stderr)
        
        elif state == "clean" and specs_todelete:
            res = ctx.run([DNF_BIN, "-q", "versionlock", "clear"], mutates=True)
            if res.rc != 0:
                fail("failed to clear versionlock: " + res.stderr)
    
    # Prepare response
    response = {
        "changed": changed,
        "msg": "",
        "locklist_pre": locklist_pre,
        "specs_toadd": specs_toadd,
        "specs_todelete": specs_todelete
    }
    
    # locklist_post
    if not ctx.check_mode:
        res = ctx.run([DNF_BIN, "-q", "versionlock", "list"], mutates=False)
        response["locklist_post"] = res.stdout.strip().split() if res.stdout.strip() else []
    else:
        if state == "clean":
            response["locklist_post"] = []
    
    # Set message
    if changed and not response["msg"]:
        if state == "clean":
            response["msg"] = "cleared versionlock"
        elif state == "absent":
            response["msg"] = "removed versionlock entries"
        else:
            response["msg"] = "added versionlock entries"
    
    return response


# Simple fnmatch helper (Starlark has no built-in fnmatch)
def fnmatch_fn(name, pattern):
    # Basic pattern matching: handle * wildcards
    if pattern == "*":
        return True
    if "*" not in pattern:
        return name == pattern
    parts = pattern.split("*")
    if len(parts) == 2:
        return name.startswith(parts[0]) and name.endswith(parts[1]) if parts[1] else name.startswith(parts[0])
    # Fallback for complex patterns: only simple prefix/suffix matching
    return name.startswith(pattern.replace("*", ""))
