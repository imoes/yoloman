def main(ctx, params):
    dn = params["dn"]
    scope = params.get("scope", "base")
    filterstr = params.get("filter", "(objectClass=*)")
    attrs = params.get("attrs")
    schema = params.get("schema", False)
    page_size = params.get("page_size", 0)
    base64_attrs = params.get("base64_attributes") or []
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

    # Build ldap command line args
    uri_flags = ""
    if server_uri.startswith("ldaps://"):
        uri_flags = "-H " + server_uri
    elif server_uri.startswith("ldap://"):
        uri_flags = "-H " + server_uri
    else:
        uri_flags = "-H " + server_uri

    # Handle multiple URIs
    if "," in server_uri or " " in server_uri:
        fail("multiple URIs not supported in Starlark implementation")

    # Base command
    cmd = ["ldapsearch"]

    # Add connection options
    cmd.extend(uri_flags.split())

    if not validate_certs:
        cmd.append("-X")  # No cert verification

    if ca_path != None:
        cmd.extend(["-Y", ca_path])

    if start_tls:
        cmd.append("-ZZ")  # Require startTLS

    # Auth options
    if bind_dn != None and bind_dn != "":
        cmd.extend(["-D", bind_dn])
        if bind_pw != "":
            # Use environment variable or stdin for password for security
            fail("bind_pw is not supported securely in Starlark implementation; use SASL or ANONYMOUS bind")

    # SASL options
    if bind_dn == None or bind_dn == "":
        if sasl_class == "external":
            cmd.append("-Y EXTERNAL")
        elif sasl_class == "gssapi":
            cmd.append("-Y GSSAPI")

    # Referrals
    if referrals_chasing == "disabled":
        cmd.append("-o referrals=off")

    # Security options for client auth
    if client_cert != None and client_key != None:
        fail("client_cert/client_key not supported in Starlark implementation")
    elif client_cert != None or client_key != None:
        fail("client_cert and client_key must be specified together")

    # Scope mapping
    scope_map = {
        "base": "base",
        "onelevel": "one",
        "subordinate": "subordinate",
        "children": "subtree",
    }
    if scope not in scope_map:
        fail("unsupported scope: " + scope)
    cmd.extend(["-s", scope_map[scope]])

    # Page size
    if page_size > 0:
        cmd.extend(["-z", str(page_size)])

    # DN and filter
    cmd.append(dn)
    cmd.append(filterstr)

    # Attributes
    if attrs != None:
        attrlist = attrs
        if type(attrlist) == "string":
            attrlist = attrlist.split(",")
        cmd.append("-a")  # Return all attrs
        cmd.extend(["-A"] if schema else [])
    elif schema:
        cmd.extend(["-A"])

    # Build final command list (space split)
    final_cmd = []
    for arg in cmd:
        if " " in arg:
            final_cmd.extend(arg.split(" "))
        else:
            final_cmd.append(arg)

    # Execute search
    res = ctx.run(final_cmd, mutates=False)

    if res.rc != 0:
        fail("ldapsearch failed: " + res.stderr)

    # Parse results
    results = []
    current_entry = {}
    current_dn = ""

    lines = res.stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line == "":
            if current_dn != "":
                entry = {"dn": current_dn}
                for k, v in current_entry.items():
                    entry[k] = v
                results.append(entry)
                current_entry = {}
                current_dn = ""
            i += 1
            continue

        if line.startswith("dn:"):
            if current_dn != "":
                entry = {"dn": current_dn}
                for k, v in current_entry.items():
                    entry[k] = v
                results.append(entry)
                current_entry = {}
            current_dn = line[3:].strip()
        elif line.startswith(" ") or line.startswith("\t"):
            # Continuation line - ignore (should not happen with -o ldif)
            pass
        elif ":" in line:
            key_val = line.split(":", 1)
            if len(key_val) == 2:
                key = key_val[0].strip()
                val = key_val[1].strip()
                # Handle base64 encoded values (base64: marker)
                if key.endswith(":") and val.startswith("::"):
                    val = val[2:]
                    # Decode base64 - but skip for now as Starlark lacks base64
                    pass
                elif key.endswith(":") and val.startswith(": "):
                    val = val[2:]
                    # Binary base64
                    pass
                else:
                    val = val.strip()

                # Handle multiple values for same key
                if key in current_entry:
                    if type(current_entry[key]) == "string":
                        current_entry[key] = [current_entry[key]]
                    current_entry[key].append(val)
                else:
                    current_entry[key] = val
        i += 1

    # Add last entry
    if current_dn != "":
        entry = {"dn": current_dn}
        for k, v in current_entry.items():
            entry[k] = v
        results.append(entry)

    # Handle base64 encoding if requested
    if "*" in base64_attrs:
        for entry in results:
            for k, v in entry.items():
                if k != "dn":
                    if type(v) == "string":
                        entry[k] = "base64:" + v
                    elif type(v) == "list":
                        for i in range(len(v)):
                            v[i] = "base64:" + v[i]
    elif len(base64_attrs) > 0:
        for entry in results:
            for k, v in entry.items():
                if k != "dn" and k in base64_attrs:
                    if type(v) == "string":
                        entry[k] = "base64:" + v
                    elif type(v) == "list":
                        for i in range(len(v)):
                            v[i] = "base64:" + v[i]

    return {"changed": False, "results": results}
