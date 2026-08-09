def main(ctx, params):
    dn = params["dn"]
    passwd = params.get("passwd")
    bind_dn = params.get("bind_dn")
    bind_pw = params.get("bind_pw", "")
    server_uri = params.get("server_uri", "ldapi:///")
    start_tls = params.get("start_tls", False)
    validate_certs = params.get("validate_certs", True)
    ca_path = params.get("ca_path")
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    referrals_chasing = params.get("referrals_chasing", "anonymous")
    sasl_class = params.get("sasl_class", "external")
    xorder_discovery = params.get("xorder_discovery", "auto")

    # Validate required params
    if passwd == None:
        fail("passwd is required")

    # Build ldap command arguments
    cmd = ["ldapmodify"]
    if server_uri.startswith("ldapi://"):
        cmd.append("-Y")
        cmd.append("EXTERNAL")
    elif server_uri.startswith("ldap://") or server_uri.startswith("ldaps://"):
        # Extract host and port if present
        uri = server_uri.replace("ldap://", "").replace("ldaps://", "").replace("ldaps://", "")
        if "@" in uri:
            host_port = uri.split("@")[-1]
        else:
            host_port = uri
        if host_port.find(":") != -1:
            host, port = host_port.split(":", 1)
        else:
            host = host_port
            port = "389"
        cmd.append("-h")
        cmd.append(host)
        cmd.append("-p")
        cmd.append(port)
        if server_uri.startswith("ldaps://"):
            cmd.append("-H")
            cmd.append("ldaps://" + host + ":" + port)
        else:
            cmd.append("-H")
            cmd.append("ldap://" + host + ":" + port)

    if start_tls:
        cmd.append("-ZZ")
    elif not validate_certs:
        cmd.append("-x")
        cmd.append("-H")
        cmd.append("ldap://" + server_uri.replace("ldap://", ""))
    else:
        cmd.append("-H")
        cmd.append("ldap://" + server_uri.replace("ldap://", ""))

    # Add bind DN if provided
    if bind_dn != None:
        cmd.append("-D")
        cmd.append(bind_dn)
        if bind_pw != "":
            cmd.append("-w")
            cmd.append(bind_pw)

    # Handle TLS/SSL options
    if ca_path != None:
        cmd.append("-X")
        cmd.append(ca_path)

    if client_cert != None or client_key != None:
        if client_cert == None or client_key == None:
            fail("client_cert and client_key must be specified together")
        cmd.append("-J")
        cmd.append(client_cert + ":" + client_key)

    # Prepare LDIF content
    ldif_lines = ["dn: " + dn, "changetype: modify", "replace: userPassword", "userPassword: " + passwd, ""]
    ldif_content = "\n".join(ldif_lines)

    # Write LDIF to temp file
    ldif_path = "/tmp/ldap_passwd.ldif"
    changed = ctx.file_write(ldif_path, ldif_content)
    if ctx.check_mode:
        # In check_mode, we only simulate the change
        res = ctx.run(["ldapmodify", "-n"] + cmd[1:] + ["-f", ldif_path])
        if res.rc != 0:
            fail("LDAP modify would fail: " + res.stderr)
        return {"changed": True, "msg": "would update password for " + dn}

    # Execute the actual ldapmodify
    res = ctx.run(cmd + ["-f", ldif_path])
    if res.rc != 0:
        fail("Failed to set password: " + res.stderr)

    return {"changed": True, "msg": "password updated for " + dn}
