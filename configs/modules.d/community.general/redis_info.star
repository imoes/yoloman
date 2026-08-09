def main(ctx, params):
    host = params.get("login_host", "localhost")
    port = params.get("login_port", 6379)
    username = params.get("login_user")
    password = params.get("login_password")
    use_tls = params.get("tls", False)
    validate_certs = params.get("validate_certs", True)
    ca_certs = params.get("ca_certs")

    # Build redis-cli command with TLS options
    cmd = ["redis-cli", "-h", str(host), "-p", str(port)]
    
    if use_tls:
        cmd.extend(["--tls"])
        if not validate_certs:
            cmd.append("--insecure")
        if ca_certs != None:
            cmd.extend(["--cacert", ca_certs])
    
    if username != None:
        cmd.extend(["-u", "redis://" + username + (":" + password if password != None else "") + "@" + host + ":" + str(port)])
    elif password != None:
        cmd.extend(["-a", password])
    
    cmd.append("INFO")
    
    # Run redis-cli INFO command
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("failed to get Redis info: " + res.stderr)
    
    # Parse INFO output into dict
    info_lines = res.stdout.splitlines()
    info = {}
    current_section = None
    
    for line in info_lines:
        if line == "" or line.startswith("#"):
            if line.startswith("# ") and len(line) > 2:
                current_section = line[2:].lower().replace(" ", "_")
            continue
        
        if ":" in line:
            key, value = line.split(":", 1)
            # Strip leading/trailing whitespace
            key = key.strip()
            value = value.strip()
            
            # Try to convert to appropriate type
            if value.isdigit():
                value = int(value)
            elif value.replace('.', '', 1).isdigit() and value.count('.') == 1:
                value = float(value)
            elif value.startswith("db") and value[2:].isdigit():
                # Handle section like "db0:keys=123,expires=45,avg_ttl=678"
                current_section = value
                continue
            elif current_section != None and "=" in value:
                # Handle nested section data
                if current_section not in info:
                    info[current_section] = {}
                for item in value.split(","):
                    if "=" in item:
                        subkey, subval = item.split("=")
                        subkey = subkey.strip()
                        subval = subval.strip()
                        if subval.isdigit():
                            subval = int(subval)
                        elif subval.replace('.', '', 1).isdigit() and subval.count('.') == 1:
                            subval = float(subval)
                        info[current_section][subkey] = subval
                current_section = None
                continue
            
            info[key] = value
    
    return {"changed": False, "data": {"info": info}}
