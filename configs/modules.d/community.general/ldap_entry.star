def main(ctx, params):
    dn = params["dn"]
    state = params.get("state", "present")
    recursive = params.get("recursive", False)
    attributes = params.get("attributes", {})
    object_class = params.get("objectClass")
    bind_dn = params.get("bind_dn")
    bind_pw = params.get("bind_pw", "")
    server_uri = params.get("server_uri", "ldapi:///")
    start_tls = params.get("start_tls", False)
    validate_certs = params.get("validate_certs", True)
    referrals_chasing = params.get("referrals_chasing", "anonymous")
    sasl_class = params.get("sasl_class", "external")
    ca_path = params.get("ca_path")
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    xorder_discovery = params.get("xorder_discovery", "auto")

    # Validate required options
    if state == "present" and object_class == None:
        fail("objectClass is required when state is present")

    # Build command arguments
    cmd = ["ldapmodify"]

    # Authentication
    if bind_dn != None and bind_dn != "":
        cmd.extend(["-D", bind_dn])
        if bind_pw != "":
            cmd.extend(["-w", bind_pw])
    else:
        cmd.append("-Y EXTERNAL")

    # Connection
    if server_uri != "ldapi:///":
        hosts = server_uri.replace(",", " ").split()
        # Use first URI for connection
        cmd.extend(["-h", hosts[0].split("://")[-1].split(":")[0]])
        if ":" in hosts[0]:
            port = hosts[0].split(":")[-1].split("/")[0]
            if port.isdigit():
                cmd.extend(["-p", port])

    if start_tls:
        cmd.append("-Z")

    if not validate_certs:
        cmd.append("-x")

    if ca_path != None:
        cmd.extend(["-H", "ldaps://" + hosts[0].split("://")[-1]])
        # Note: ldapmodify doesn't directly support CA file; this is handled via env or system config
        # For Starlark simulation, we rely on system-level certificate handling

    # Prepare entry content
    lines = ["dn: " + dn, "changetype: modify"]

    if state == "present":
        # Build attributes
        attr_dict = dict(attributes)  # Copy
        if object_class != None:
            if type(object_class) == "string":
                attr_dict["objectClass"] = [object_class]
            else:
                attr_dict["objectClass"] = object_class

        # Generate LDIF content for adding entry
        # Since we can't modify existing entries, we'll simulate add if not present
        if not _ldap_entry_exists(ctx, dn, server_uri, bind_dn, bind_pw, validate_certs, ca_path, start_tls):
            lines = ["dn: " + dn, "changeType: add"]
            for attr, vals in sorted(attr_dict.items()):
                if type(vals) != "list":
                    vals = [vals]
                for val in vals:
                    lines.append(attr + ": " + str(val))
            lines.append("")  # End with blank line

            ldif_content = "\n".join(lines)

            if ctx.check_mode:
                return {"changed": True, "msg": "would add entry " + dn}

            # Use ldapadd for add operation
            cmd = ["ldapadd"] + cmd[1:]
            res = ctx.run(cmd, stdin=ldif_content, mutates=True)
            if res.rc != 0:
                fail("failed to add entry " + dn + ": " + res.stderr)
            return {"changed": True, "msg": "added entry " + dn}
        else:
            return {"changed": False, "msg": "entry " + dn + " already exists"}

    elif state == "absent":
        if not _ldap_entry_exists(ctx, dn, server_uri, bind_dn, bind_pw, validate_certs, ca_path, start_tls):
            return {"changed": False, "msg": "entry " + dn + " does not exist"}

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete entry " + dn}

        if recursive:
            # Recursive delete using ldapdelete -r
            cmd.append("-r")

        cmd.append(dn)

        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("failed to delete entry " + dn + ": " + res.stderr)
        return {"changed": True, "msg": "deleted entry " + dn}

    fail("unsupported state: " + state)


def _ldap_entry_exists(ctx, dn, server_uri, bind_dn, bind_pw, validate_certs, ca_path, start_tls):
    # Build ldapsearch command to check if entry exists
    cmd = ["ldapsearch", "-x", "-b", dn, "-s base", "(objectClass=*)", "dn"]

    # Authentication
    if bind_dn != None and bind_dn != "":
        cmd.extend(["-D", bind_dn])
        if bind_pw != "":
            cmd.extend(["-w", bind_pw])
    else:
        cmd.extend(["-Y", "EXTERNAL"])

    # Connection
    if server_uri != "ldapi:///":
        host = server_uri.split("://")[-1].split("/")[0]
        if ":" in host:
            parts = host.split(":")
            cmd.extend(["-h", parts[0]])
            if parts[1].isdigit():
                cmd.extend(["-p", parts[1]])
        else:
            cmd.extend(["-h", host])

    if start_tls:
        cmd.append("-Z")

    if not validate_certs:
        cmd.append("-x")

    if ca_path != None:
        # Note: ldapsearch supports -H for LDAPS; use ssl:// or ldaps:// as needed
        if "ldaps://" in server_uri:
            cmd.append("-H " + server_uri)
        # For simplicity, rely on system CA trust

    res = ctx.run(cmd, mutates=False)
    return res.rc == 0
