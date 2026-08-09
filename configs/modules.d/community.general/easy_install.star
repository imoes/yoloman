def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    virtualenv = params.get("virtualenv")
    virtualenv_site_packages = params.get("virtualenv_site_packages", False)
    virtualenv_command = params.get("virtualenv_command", "virtualenv")
    executable = params.get("executable", "easy_install")
    
    # Prepare executable arguments for dry-run and install
    executable_arguments = []
    if state == "latest":
        executable_arguments.append("--upgrade")
    executable_arguments.append("--dry-run")
    
    # Determine easy_install path
    def find_easy_install(env_dir, exe):
        # First check if executable is absolute path
        if exe.startswith("/"):
            return exe
        # Try bin path in virtualenv if provided
        if env_dir != None:
            candidate = env_dir + "/bin/" + exe
            if ctx.file_exists(candidate):
                return candidate
        # Try system PATH
        res = ctx.run(["which", exe])
        if res.rc == 0:
            return res.stdout.strip()
        fail("Could not find easy_install executable")
    
    # Check/create virtualenv if specified
    if virtualenv != None:
        venv_bin = virtualenv + "/bin"
        if not ctx.file_exists(virtualenv + "/bin/activate"):
            # Check mode: predict change
            if ctx.check_mode:
                return {"changed": True, "msg": "would create virtualenv"}
            
            # Create virtualenv
            cmd = [virtualenv_command, virtualenv]
            if virtualenv_site_packages:
                cmd.append("--system-site-packages")
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("Failed to create virtualenv: " + res.stderr)
    
    easy_install_path = find_easy_install(virtualenv, executable)
    
    # Check if package is installed (dry-run mode)
    def is_installed():
        cmd = [easy_install_path] + executable_arguments + [name]
        # For dry-run, we need the full list without --dry-run for actual install
        # But here we want dry-run output to detect presence
        dry_run_cmd = cmd
        res = ctx.run(dry_run_cmd, mutates=False)
        # If rc != 0 or 'Downloading' appears, it's not installed
        if res.rc != 0:
            return False
        return "Downloading" not in res.stdout
    
    installed = is_installed()
    
    # If not installed (or need upgrade for latest), install it
    if not installed:
        if ctx.check_mode:
            return {"changed": True, "msg": "would install " + name}
        
        # Prepare actual install command (without --dry-run)
        install_args = [easy_install_path]
        if state == "latest":
            install_args.append("--upgrade")
        install_args.append(name)
        
        res = ctx.run(install_args, mutates=True)
        if res.rc != 0:
            fail("Failed to install " + name + ": " + res.stderr)
        
        return {"changed": True, "msg": "installed " + name, "data": {"executable": easy_install_path}}
    
    # Already installed
    return {"changed": False, "msg": name + " already installed", "data": {"executable": easy_install_path}}
