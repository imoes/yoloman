def main(ctx, params):
    name = params["name"]
    host = params.get("host", "copr.fedorainfracloud.org")
    protocol = params.get("protocol", "https")
    state = params.get("state", "enabled")
    chroot = params.get("chroot")

    # Basic validation
    if not name or "/" not in name:
        fail("name must be in the format 'user/project' or '@group/project'")
    
    # Extract user/group and project
    parts = name.split("/", 1)
    user = parts[0]
    project = parts[1]
    
    # Sanitize username for group names
    if user.startswith("@"):
        user = "group_" + user[1:]
    
    # Determine chroot if not provided
    if not chroot:
        facts = ctx.facts()
        distribution = facts.get("distribution", "").lower()
        version = ""
        arch = facts.get("architecture", "x86_64")
        
        # Map OS family to short name
        if distribution.startswith("fedora"):
            distribution = "fedora"
            version = facts.get("distribution_version", "")
        elif distribution.startswith("centos"):
            distribution = "centos"
            version = facts.get("distribution_version", "")
        elif distribution.startswith("rhel"):
            distribution = "rhel"
            version = facts.get("distribution_version", "")
        elif distribution.startswith("epel"):
            distribution = "epel"
            version = facts.get("distribution_version", "").replace("el", "")
        else:
            fail("unsupported distribution: " + distribution)
        
        if not version:
            fail("could not determine OS version")
        
        # Format chroot
        chroot = distribution + "-" + version + "-" + arch
    else:
        chroot = chroot
    
    # Extract short_chroot (distribution-version)
    short_chroot = chroot.rsplit("-", 1)[0]
    
    # Determine repo filename and path
    repo_filename = "_copr:" + host + ":" + user + ":" + project + ".repo"
    repo_path = "/etc/yum.repos.d/" + repo_filename
    
    # Get base architecture from chroot
    arch = chroot.split("-")[-1]
    
    # Build repo URL
    repo_url = protocol + "://" + host + "/coprs/" + name + "/repo/" + short_chroot + "/dnf.repo?arch=" + arch
    
    # Helper function to fetch repo content
    def fetch_repo_content():
        # Try to download the repo file using curl
        res = ctx.run(["curl", "-sSLf", repo_url])
        if res.rc != 0:
            fail("failed to fetch repo: " + res.stderr)
        return res.stdout
    
    # Check current repo state
    current_repo_content = ""
    repo_exists = ctx.file_exists(repo_path)
    
    if repo_exists:
        current_repo_content = ctx.file_read(repo_path)
    
    # Download API content
    res = ctx.run(["curl", "-sSLf", repo_url])
    if res.rc != 0:
        fail("chroot " + short_chroot + " does not exist in " + name)
    api_repo_content = res.stdout
    
    # Compare content (ignoring enabled/disabled state)
    def normalize_content(content):
        lines = content.split("\n")
        normalized = []
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("enabled="):
                continue  # Skip enabled flag for comparison
            if stripped == "":
                continue  # Skip empty lines
            normalized.append(stripped)
        return "\n".join(normalized)
    
    current_normalized = normalize_content(current_repo_content) if current_repo_content else ""
    api_normalized = normalize_content(api_repo_content)
    
    if state == "enabled":
        if repo_exists and current_normalized == api_normalized:
            return {"changed": False, "msg": "already enabled", 
                    "repo": host + "/" + user + "/" + project, 
                    "repo_filename": repo_filename}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would enable", 
                        "repo": host + "/" + user + "/" + project, 
                        "repo_filename": repo_filename}
            # Enable by writing the repo file
            ctx.file_write(repo_path, api_repo_content, "0644")
            return {"changed": True, "msg": "enabled", 
                    "repo": host + "/" + user + "/" + project, 
                    "repo_filename": repo_filename}
    
    elif state == "disabled":
        if repo_exists and current_normalized == api_normalized:
            # Check if already disabled
            if "enabled=0" in current_repo_content:
                return {"changed": False, "msg": "already disabled", 
                        "repo": host + "/" + user + "/" + project, 
                        "repo_filename": repo_filename}
            # Modify in place to disable (in non-check mode)
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable", 
                        "repo": host + "/" + user + "/" + project, 
                        "repo_filename": repo_filename}
            # Replace enabled=1 with enabled=0
            updated = current_repo_content.replace("enabled=1", "enabled=0")
            ctx.file_write(repo_path, updated, "0644")
            return {"changed": True, "msg": "disabled", 
                    "repo": host + "/" + user + "/" + project, 
                    "repo_filename": repo_filename}
        else:
            # Need to first fetch and then disable
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable", 
                        "repo": host + "/" + user + "/" + project, 
                        "repo_filename": repo_filename}
            # Create the repo file and disable it
            disabled_content = api_repo_content.replace("enabled=1", "enabled=0")
            ctx.file_write(repo_path, disabled_content, "0644")
            return {"changed": True, "msg": "disabled", 
                    "repo": host + "/" + user + "/" + project, 
                    "repo_filename": repo_filename}
    
    elif state == "absent":
        if not repo_exists:
            return {"changed": False, "msg": "already absent", 
                    "repo": host + "/" + user + "/" + project, 
                    "repo_filename": repo_filename}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would remove", 
                        "repo": host + "/" + user + "/" + project, 
                        "repo_filename": repo_filename}
            # Remove the repo file
            ctx.file_write(repo_path, "", "0644")  # Will be ignored if we use file_exists check
            # Use a shell command to remove file
            res = ctx.run(["rm", "-f", repo_path], mutates=True)
            if res.rc != 0 and not res.skipped:
                fail("failed to remove repo file: " + res.stderr)
            return {"changed": True, "msg": "removed", 
                    "repo": host + "/" + user + "/" + project, 
                    "repo_filename": repo_filename}
    
    else:
        fail("unsupported state: " + state)
