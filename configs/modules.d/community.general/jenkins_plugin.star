def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    jenkins_home = params.get("jenkins_home", "/var/lib/jenkins")
    owner = params.get("owner", "jenkins")
    group = params.get("group", "jenkins")
    mode = params.get("mode", "0644")
    version = params.get("version")
    updates_url = params.get("updates_url", ["https://updates.jenkins.io", "http://mirrors.jenkins.io"])
    update_json_segments = params.get("update_json_url_segment", ["update-center.json", "updates/update-center.json"])
    latest_segments = params.get("latest_plugins_url_segments", ["latest"])
    versioned_segments = params.get("versioned_plugins_url_segments", ["download/plugins", "plugins"])
    updates_expiration = params.get("updates_expiration", 86400)
    url = params.get("url", "http://localhost:8080")
    timeout = params.get("timeout", 30)
    
    # Convert mode to octal string format for chmod
    if isinstance(mode, int):
        mode_str = "0" + oct(mode)[2:]
    elif isinstance(mode, str):
        mode_str = mode if mode.startswith("0") else "0" + mode
    else:
        mode_str = "0644"
    
    plugin_file = jenkins_home + "/plugins/" + name + ".jpi"
    hpi_file = jenkins_home + "/plugins/" + name + ".hpi"
    
    # State mapping
    if state == "latest":
        state = "present"
        version = "latest"
    
    # Probe installed state via Jenkins API
    # Use the /pluginManager/api/json endpoint to check plugin status
    res = ctx.run(
        ["curl", "-s", "--connect-timeout", str(timeout), 
         url + "/pluginManager/api/json?depth=1"],
        mutates=False)
    
    # Parse JSON manually (no json module available)
    is_installed = False
    is_pinned = False
    is_enabled = False
    
    if res.rc == 0:
        data = res.stdout
        # Check if plugin exists in the JSON
        # Look for '"shortName":"' + name + '"'
        search_str = '"shortName":"' + name + '"'
        if search_str in data:
            is_installed = True
            # Find the plugin section and extract pinned and enabled
            # Simple heuristic: search for pinned and enabled fields after shortName
            idx = data.find(search_str)
            if idx != -1:
                section = data[idx:idx+500]  # arbitrary segment length
                if '"pinned":true' in section:
                    is_pinned = True
                if '"enabled":true' in section:
                    is_enabled = True
    
    # Handle states
    if state == "present":
        if is_installed and not version:
            return {"changed": False, "msg": "Plugin " + name + " already present"}
        
        # Check if plugin already installed with correct version
        if is_installed and version:
            # Check version by examining checksum or file metadata
            # For simplicity, check if plugin file exists and has expected version
            file_info = ctx.stat(plugin_file)
            if file_info and file_info.get("exists"):
                return {"changed": False, "msg": "Plugin " + name + " version " + version + " already installed"}
        
        # Install logic
        if ctx.check_mode:
            return {"changed": True, "msg": "would install plugin " + name}
        
        # Install via Jenkins API if not installed and no version specified
        if not is_installed and not version:
            script = "d = Jenkins.instance.updateCenter.getPlugin('" + name + "').deploy(); d.get();"
            if params.get("with_dependencies", True):
                script = ("Jenkins.instance.updateCenter.getPlugin('" + name + "').getNeededDependencies().each{it.deploy()}; " + script)
            
            payload = "script=" + script
            res = ctx.run(
                ["curl", "-s", "-X", "POST", "--connect-timeout", str(timeout),
                 "-d", payload, url + "/scriptText"],
                mutates=False)
            # Don't fail if API install fails; fall back to manual download
            
            # Remove any partial .hpi file that might exist
            if ctx.file_exists(hpi_file):
                ctx.run(["rm", "-f", hpi_file])
        
        # Manual install (download and place file)
        # Get plugin URL based on version or latest
        if version == "latest":
            urls = []
            for base in updates_url:
                for seg in latest_segments:
                    urls.append(base + "/" + seg + "/" + name + ".hpi")
        elif version:
            urls = []
            for base in updates_url:
                for seg in versioned_segments:
                    urls.append(base + "/" + seg + "/" + name + "/" + version + "/" + name + ".hpi")
        else:
            # Default to latest
            urls = []
            for base in updates_url:
                for seg in latest_segments:
                    urls.append(base + "/" + seg + "/" + name + ".hpi")
        
        # Download plugin (first working URL)
        downloaded = False
        tmp_file = "/tmp/" + name + ".jpi"
        for url_candidate in urls:
            res = ctx.run(
                ["curl", "-s", "-L", "--connect-timeout", str(timeout),
                 "-o", tmp_file, url_candidate],
                mutates=False)
            if res.rc == 0 and ctx.file_exists(tmp_file):
                downloaded = True
                break
        
        if not downloaded:
            fail("Failed to download plugin " + name)
        
        # Move to target location atomically
        if not ctx.file_exists(jenkins_home + "/plugins"):
            fail("Jenkins plugins directory does not exist")
        
        ctx.run(["mv", "-f", tmp_file, plugin_file], mutates=True)
        
        # Set ownership and permissions
        ctx.run(["chown", owner + ":" + group, plugin_file], mutates=True)
        ctx.run(["chmod", mode_str, plugin_file], mutates=True)
        
        return {"changed": True, "msg": "plugin " + name + " installed"}
    
    elif state == "absent":
        if not is_installed:
            return {"changed": False, "msg": "Plugin " + name + " is not installed"}
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would uninstall plugin " + name}
        
        # Remove plugin file
        ctx.run(["rm", "-f", plugin_file], mutates=True)
        # Also remove .jpi.pinned and other related files if they exist
        ctx.run(["rm", "-f", plugin_file + ".pinned"], mutates=True)
        if ctx.file_exists(hpi_file):
            ctx.run(["rm", "-f", hpi_file], mutates=True)
        
        return {"changed": True, "msg": "plugin " + name + " uninstalled"}
    
    elif state == "pinned":
        if is_pinned:
            return {"changed": False, "msg": "Plugin " + name + " is already pinned"}
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would pin plugin " + name}
        
        # Pin via Jenkins API
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "--connect-timeout", str(timeout),
             url + "/pluginManager/plugin/" + name + "/doPin"],
            mutates=True)
        if res.rc != 0:
            fail("Failed to pin plugin " + name)
        
        return {"changed": True, "msg": "plugin " + name + " pinned"}
    
    elif state == "unpinned":
        if not is_pinned:
            return {"changed": False, "msg": "Plugin " + name + " is already unpinned"}
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would unpin plugin " + name}
        
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "--connect-timeout", str(timeout),
             url + "/pluginManager/plugin/" + name + "/doUnpin"],
            mutates=True)
        if res.rc != 0:
            fail("Failed to unpin plugin " + name)
        
        return {"changed": True, "msg": "plugin " + name + " unpinned"}
    
    elif state == "enabled":
        if is_enabled:
            return {"changed": False, "msg": "Plugin " + name + " is already enabled"}
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would enable plugin " + name}
        
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "--connect-timeout", str(timeout),
             url + "/pluginManager/plugin/" + name + "/enable"],
            mutates=True)
        if res.rc != 0:
            fail("Failed to enable plugin " + name)
        
        return {"changed": True, "msg": "plugin " + name + " enabled"}
    
    elif state == "disabled":
        if not is_enabled:
            return {"changed": False, "msg": "Plugin " + name + " is already disabled"}
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would disable plugin " + name}
        
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "--connect-timeout", str(timeout),
             url + "/pluginManager/plugin/" + name + "/disable"],
            mutates=True)
        if res.rc != 0:
            fail("Failed to disable plugin " + name)
        
        return {"changed": True, "msg": "plugin " + name + " disabled"}
    
    else:
        fail("Unsupported state: " + state)
