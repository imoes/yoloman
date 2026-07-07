def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    accept_license = params.get("accept_license", False)
    repository_path = params.get("repository_path")

    # Validate required parameters
    if state == "present" and repository_path == None:
        fail("repository_path is required to install package")

    # Get bin paths
    installp_path = ctx.run(["which", "installp"], mutates=False).stdout.strip()
    if installp_path == "":
        fail("installp command not found")
    lslpp_path = ctx.run(["which", "lslpp"], mutates=False).stdout.strip()
    if lslpp_path == "":
        fail("lslpp command not found")

    # Helper functions
    def check_pkg_in_repo(package, repo_path):
        """Check if package exists in repository."""
        if not ctx.file_exists(repo_path) or not ctx.stat(repo_path).get("is_dir", False):
            fail("Repository path %s is not valid." % repo_path)
        
        res = ctx.run([installp_path, "-l", "-MR", "-d", repo_path], mutates=False)
        if res.rc != 0:
            fail("Failed to run installp -l -MR: " + res.stderr)
        
        if package == "all":
            return True, "All packages on dir"
        
        # Parse output for package matches
        for line in res.stdout.splitlines():
            if line.strip() == "":
                continue
            parts = line.split()
            if len(parts) >= 2 and package == parts[0].strip():
                return True, {parts[0].strip(): parts[1].strip()}
        
        return False, None

    def check_pkg_installed(package):
        """Check if package is installed on the system."""
        res = ctx.run([lslpp_path, "-lcq", package + "*"], mutates=False)
        
        if res.rc == 1:
            # Check if "not installed." appears in stderr
            if "not installed." in res.stderr:
                return False, None
            fail("Failed to run lslpp: " + res.stderr)
        
        if res.rc != 0:
            fail("Failed to run lslpp: " + res.stderr)
        
        pkg_data = {}
        for line in res.stdout.splitlines():
            parts = line.split(":")
            if len(parts) >= 3:
                pkg_data[parts[0]] = (parts[1], parts[2])
        
        return True, pkg_data

    def is_package_installed_in_repo(package, repo_path):
        """Check if package is already installed (returns version if installed)."""
        installed, pkg_info = check_pkg_installed(package)
        if not installed:
            return False, None
        
        # Check if package name matches directly or as fileset
        if package in pkg_info:
            return True, pkg_info[package][1]
        
        # Check filesets
        for pkg_name in pkg_info:
            fileset, level = pkg_info[pkg_name]
            if package == fileset or fileset.startswith(package):
                return True, level
        
        return False, None

    # State processing
    if state == "absent":
        removed_pkgs = []
        not_found_pkgs = []
        for package in name:
            installed, _ = check_pkg_installed(package)
            if installed:
                if not ctx.check_mode:
                    res = ctx.run([installp_path, "-u", package], mutates=True)
                    if res.rc != 0:
                        fail("Failed to uninstall package " + package + ": " + res.stderr)
                removed_pkgs.append(package)
            else:
                not_found_pkgs.append(package)
        
        if len(removed_pkgs) > 0:
            msg = "Packages removed: " + " ".join(removed_pkgs)
            if len(not_found_pkgs) > 0:
                msg = msg + ". Package(s) not found: " + " ".join(not_found_pkgs)
            return {"changed": True, "msg": msg}
        else:
            return {"changed": False, "msg": "No packages removed, all packages not found: " + " ".join(not_found_pkgs)}

    elif state == "present":
        installed_pkgs = []
        not_found_pkgs = []
        already_installed_pkgs = {}
        accept_flag = "-Y" if accept_license else ""

        # Validate packages exist in repository
        for package in name:
            pkg_check, pkg_data = check_pkg_in_repo(package, repository_path)

            if pkg_check:
                # Check if package is already installed
                installed, version = is_package_installed_in_repo(package, repository_path)
                if installed:
                    already_installed_pkgs[package] = version
                else:
                    if not ctx.check_mode:
                        res = ctx.run([installp_path, "-a", accept_flag, "-X", "-d", repository_path, package], mutates=True)
                        if res.rc != 0:
                            fail("Failed to install package " + package + ": " + res.stderr)
                    installed_pkgs.append(package)
            else:
                not_found_pkgs.append(package)

        # Build result message
        parts = []
        if len(installed_pkgs) > 0:
            parts.append("Installed: " + " ".join(installed_pkgs))
        if len(not_found_pkgs) > 0:
            parts.append("Not found: " + " ".join(not_found_pkgs))
        if len(already_installed_pkgs) > 0:
            already_list = ""
            for k in already_installed_pkgs:
                if already_list != "":
                    already_list = already_list + ", "
                already_list = already_list + k + "=" + already_installed_pkgs[k]
            parts.append("Already installed: " + already_list)
        
        if len(installed_pkgs) > 0:
            return {"changed": True, "msg": ". ".join(parts)}
        else:
            return {"changed": False, "msg": "No packages installed. " + ". ".join(parts)}

    fail("Unexpected state: " + state)
