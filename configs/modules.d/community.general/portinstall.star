def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    use_packages = params.get("use_packages", True)

    # Split comma-separated package list
    packages = name.split(",")

    # Determine pkg_info path (for legacy pkgng detection)
    pkg_info_res = ctx.run(["which", "pkg_info"], mutates=False)
    pkg_info_path = None if pkg_info_res.rc != 0 else "pkg_info"
    
    # Determine portinstall path
    portinstall_res = ctx.run(["which", "portinstall"], mutates=False)
    portinstall_path = None if portinstall_res.rc != 0 else "portinstall"

    # Ensure portinstall is available (install portupgrade if missing)
    if portinstall_path == None:
        pkg_path_res = ctx.run(["which", "pkg"], mutates=False)
        if pkg_path_res.rc == 0:
            # Install portupgrade (includes portinstall)
            install_portupgrade = ctx.run(
                ["pkg", "install", "-y", "portupgrade"], 
                mutates=True
            )
            if install_portupgrade.rc != 0:
                fail("failed to install portupgrade")
            
            # Retry finding portinstall
            portinstall_res = ctx.run(["which", "portinstall"], mutates=False)
            portinstall_path = None if portinstall_res.rc != 0 else "portinstall"
            if portinstall_path == None:
                fail("portinstall not found after installing portupgrade")
    
    # Helper to remove digits from package name (re.sub('[0-9]', '', x))
    def remove_digits(s):
        result = ""
        for i in range(len(s)):
            c = s[i]
            if c != '0' and c != '1' and c != '2' and c != '3' and c != '4' and c != '5' and c != '6' and c != '7' and c != '8' and c != '9':
                result = result + c
        return result

    # Query function implementation
    def query_package(pkg_name):
        if pkg_info_path != None:
            # Legacy pkg_info path
            pkg_glob_res = ctx.run(["which", "pkg_glob"], mutates=False)
            if pkg_glob_res.rc != 0:
                return False
            # Use shell to execute `pkg_glob` within command substitution
            cmd = ["sh", "-c", pkg_info_path + " -e `pkg_glob " + pkg_name + "`"]
            res = ctx.run(cmd, mutates=False)
            found = res.rc == 0
            if not found:
                # Try name without digits (e.g., mysql55-client -> mysql-client)
                name_without_digits = remove_digits(pkg_name)
                if name_without_digits != pkg_name:
                    cmd2 = ["sh", "-c", pkg_info_path + " -e `pkg_glob " + name_without_digits + "`"]
                    res2 = ctx.run(cmd2, mutates=False)
                    found = res2.rc == 0
            return found
        else:
            # pkgng path
            pkg_info_cmd = ["pkg", "info", pkg_name]
            res = ctx.run(pkg_info_cmd, mutates=False)
            found = res.rc == 0
            if not found:
                # Try name without digits
                name_without_digits = remove_digits(pkg_name)
                if name_without_digits != pkg_name:
                    cmd2 = ["pkg", "info", name_without_digits]
                    res2 = ctx.run(cmd2, mutates=False)
                    found = res2.rc == 0
            return found

    # Remove packages implementation
    def remove_packages(pkgs):
        remove_count = 0
        pkg_glob_res = ctx.run(["which", "pkg_glob"], mutates=False)
        pkg_glob_path = None if pkg_glob_res.rc != 0 else "pkg_glob"

        pkg_delete_path = None
        pkg_delete_res = ctx.run(["which", "pkg_delete"], mutates=False)
        if pkg_delete_res.rc == 0:
            pkg_delete_path = "pkg_delete"
        else:
            pkg_path_res = ctx.run(["which", "pkg"], mutates=False)
            if pkg_path_res.rc == 0:
                pkg_delete_path = "pkg"
            else:
                fail("no package deletion tool found")
        
        for package in pkgs:
            if not query_package(package):
                continue
            
            delete_cmd = ["sh", "-c", pkg_delete_path + " `pkg_glob " + package + "`"]
            if pkg_delete_path == "pkg":
                delete_cmd = ["pkg", "delete", "-y", package]
            
            delete_res = ctx.run(delete_cmd, mutates=True)
            if delete_res.skipped:
                # Check mode: return predicted change
                return {"changed": True, "msg": "would remove package(s)"}
            if delete_res.rc != 0:
                fail("failed to remove " + package + ": " + delete_res.stderr)
            
            # Verify removal
            if query_package(package):
                # Try name without digits
                name_without_digits = remove_digits(package)
                if name_without_digits != package:
                    delete_cmd2 = ["sh", "-c", pkg_delete_path + " `pkg_glob " + name_without_digits + "`"]
                    if pkg_delete_path == "pkg":
                        delete_cmd2 = ["pkg", "delete", "-y", name_without_digits]
                    delete_res2 = ctx.run(delete_cmd2, mutates=True)
                    if delete_res2.skipped:
                        return {"changed": True, "msg": "would remove package(s)"}
                    if delete_res2.rc != 0:
                        fail("failed to remove " + package + " (with name_without_digits): " + delete_res2.stderr)
                
                if query_package(package):
                    fail("failed to remove " + package)
            
            remove_count += 1
        
        return {"changed": remove_count > 0, "msg": "removed " + str(remove_count) + " package(s)" if remove_count > 0 else "package(s) already absent"}

    # Install packages implementation
    def install_packages(pkgs, use_pkgs):
        install_count = 0
        portinstall_params = "--use-packages" if use_pkgs else ""
        
        for package in pkgs:
            if query_package(package):
                continue
            
            # Check matches using ports_glob
            ports_glob_res = ctx.run(["which", "ports_glob"], mutates=False)
            if ports_glob_res.rc != 0:
                fail("ports_glob not found")
            
            match_cmd = ["sh", "-c", "ports_glob " + package]
            match_res = ctx.run(match_cmd, mutates=False)
            occurrences = match_res.stdout.count("\n")
            
            if occurrences == 0:
                # Try name without digits
                name_without_digits = remove_digits(package)
                if name_without_digits != package:
                    match_cmd2 = ["sh", "-c", "ports_glob " + name_without_digits]
                    match_res2 = ctx.run(match_cmd2, mutates=False)
                    occurrences = match_res2.stdout.count("\n")
            
            if occurrences == 1:
                install_cmd = ["sh", "-c", portinstall_path + " --batch " + portinstall_params + " " + package]
                install_res = ctx.run(install_cmd, mutates=True)
                if install_res.skipped:
                    return {"changed": True, "msg": "would install package(s)"}
                if install_res.rc != 0:
                    fail("failed to install " + package + ": " + install_res.stderr)
                
                if not query_package(package):
                    fail("failed to install " + package)
            elif occurrences == 0:
                fail("no matches for package " + package)
            else:
                fail(str(occurrences) + " matches found for package name " + package)
            
            install_count += 1
        
        return {"changed": install_count > 0, "msg": "present " + str(install_count) + " package(s)" if install_count > 0 else "package(s) already present"}
    
    if state == "absent":
        return remove_packages(packages)
    elif state == "present":
        return install_packages(packages, use_packages)
    else:
        fail("unsupported state: " + state)
