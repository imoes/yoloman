def main(ctx, params):
    # Read sshd_config file directly
    config_path = "/etc/ssh/sshd_config"
    if not ctx.file_exists(config_path):
        return {"changed": False, "msg": "SSH daemon configuration not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    content = ctx.file_read(config_path)
    
    # Parse sshd_config - collect ports and relevant options
    ports = []
    section = {}
    
    # Relevant singular options parsers (case-insensitive matching)
    relevant_keys = [
        "protocol",
        "permitrootlogin",
        "passwordauthentication",
        "permitemptypasswords",
        "challengeresponseauthentication",
        "kbdinteractiveauthentication",
        "x11forwarding",
        "usepam",
        "ciphers"
    ]
    
    # Helper functions
    def _map_permit_root_login(value):
        v = value.lower()
        if v == "prohibit-password" or v == "without-password":
            return "key-based"
        return value
    
    def _process_line(line):
        # Skip empty lines and comments
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            return
        
        # Split on whitespace
        parts = stripped.split(None, 1)
        if len(parts) < 1:
            return
        
        key = parts[0].lower()
        
        # Handle Port (special case - can be multiple)
        if key == "port" and len(parts) > 1:
            port_str = parts[1]
            if port_str.isdigit():
                ports.append(int(port_str))
            return
        
        # Skip if not a relevant option
        found = False
        for rk in relevant_keys:
            if rk == key:
                found = True
                break
        if not found:
            return
        
        # Get value (everything after the key)
        value = parts[1] if len(parts) > 1 else ""
        
        # Apply parser logic
        if key == "protocol":
            # Sort comma-separated protocols
            protocols = []
            for p in value.split(","):
                p_stripped = p.strip()
                if p_stripped != "":
                    protocols.append(p_stripped)
            protocols = sorted(protocols)
            section[key] = ",".join(protocols)
        elif key == "permitrootlogin":
            section[key] = _map_permit_root_login(value)
        elif key == "ciphers":
            # Sort comma-separated ciphers
            ciphers = []
            for c in value.split(","):
                c_stripped = c.strip()
                if c_stripped != "":
                    ciphers.append(c_stripped)
            ciphers = sorted(ciphers)
            section[key] = ciphers
        else:
            section[key] = value
    
    # Parse each line
    for line in content.splitlines():
        _process_line(line)
    
    # Add ports if found
    if len(ports) > 0:
        section["port"] = ports
    
    # Build human-readable mapping
    options_to_human = {
        "protocol": "Protocols",
        "port": "Ports",
        "permitrootlogin": "Permit root login",
        "passwordauthentication": "Allow password authentication",
        "permitemptypasswords": "Permit empty passwords",
        "kbdinteractiveauthentication": "Allow keyboard-interactive authentication",
        "challengeresponseauthentication": "Allow challenge-response authentication",
        "x11forwarding": "Permit X11 forwarding",
        "usepam": "Use pluggable authentication module",
        "ciphers": "Ciphers"
    }
    
    missing_options_to_human = {
        "kbdinteractiveauthentication": "Allow keyboard-interactive/challenge-response authentication",
        "challengeresponseauthentication": "Allow keyboard-interactive/challenge-response authentication"
    }
    
    # Adjust params (handle deprecated names and permitrootlogin)
    adjusted_params = {}
    for option in params:
        value = params[option]
        
        # Handle deprecated names
        if option == "kbdinteractiveauthentication" and section.get("challengeresponseauthentication", None) != None:
            option = "challengeresponseauthentication"
        
        # Special handling for permitrootlogin
        if option == "permitrootlogin" and value == "without-password":
            value = "key-based"
        
        adjusted_params[option] = value
    
    # Build results
    results = []
    state = "OK"
    
    # Check section options
    for option in sorted(section.keys()):
        val = section[option]
        human_name = option
        if option in options_to_human:
            human_name = options_to_human[option]
        
        # Format value for display
        if type(val) == "list":
            val_str = ", ".join([str(v) for v in val])
        else:
            val_str = str(val)
        
        summary = "%s: %s" % (human_name, val_str)
        
        # Check against expected value
        if option in adjusted_params:
            expected = adjusted_params[option]
            if type(expected) == "list":
                expected_str = ", ".join([str(v) for v in expected])
            else:
                expected_str = str(expected)
            
            # Normalize for comparison (handle lists)
            if type(val) == "list" and type(expected) == "list":
                if val != expected:
                    state = "CRIT"
                    summary = "%s (expected %s)" % (summary, expected_str)
            elif type(val) == "list" or type(expected) == "list":
                # One is list, one is not - compare string representations
                if str(val) != str(expected):
                    state = "CRIT"
                    summary = "%s (expected %s)" % (summary, expected_str)
            else:
                if str(val) != str(expected):
                    state = "CRIT"
                    summary = "%s (expected %s)" % (summary, expected_str)
        
        results.append(summary)
    
    # Check for missing expected options
    for option in sorted(adjusted_params.keys()):
        found = False
        for section_key in section.keys():
            if section_key == option:
                found = True
                break
        if not found:
            human_name = option
            if option in missing_options_to_human:
                human_name = missing_options_to_human[option]
            elif option in options_to_human:
                human_name = options_to_human[option]
            summary = "%s: not present in SSH daemon configuration" % human_name
            state = "CRIT"
            results.append(summary)
    
    # Determine overall state
    final_state = "OK"
    if state == "CRIT":
        final_state = "CRIT"
    elif state == "WARN":
        final_state = "WARN"
    
    # Return check result
    return {"changed": False, "msg": "; ".join(results),
            "data": {"state": final_state, "metrics": {}, "details": ""}}