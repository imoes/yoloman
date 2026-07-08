def main(ctx, params):
    dn = params["dn"]
    attributes = params["attributes"]
    state = params.get("state", "present")
    ordered = params.get("ordered", False)
    bind_dn = params.get("bind_dn")
    bind_pw = params.get("bind_pw", "")
    server_uri = params.get("server_uri", "ldapi:///")
    start_tls = params.get("start_tls", False)
    validate_certs = params.get("validate_certs", True)
    referrals_chasing = params.get("referrals_chasing", "anonymous")
    sasl_class = params.get("sasl_class", "external")

    # Build base ldapmodify command
    base_cmd = ["ldapmodify"]
    uri = server_uri.split(",")[0].strip()
    if uri.startswith("ldaps://") or uri.startswith("ldap://"):
        host_port = uri.split("://")[1].split("/")[0]
        base_cmd.extend(["-h", host_port.split(":")[0]])
        if ":" in host_port:
            base_cmd.extend(["-p", host_port.split(":")[1]])
    if uri.startswith("ldapi://"):
        base_cmd.extend(["-H", uri])
    if start_tls:
        base_cmd.append("-Z")
    if not validate_certs:
        base_cmd.append("-P 2")
    if bind_dn != None:
        base_cmd.extend(["-D", bind_dn])

    # Helper to escape LDAP filter values
    def ldap_escape(val):
        return val.replace("\\", "\\5c").replace("*", "\\2a").replace("(", "\\28").replace(")", "\\29")

    # Build LDIF content
    lines = ["dn: " + dn, "changetype: modify"]
    modlist = []

    for attr_name, attr_values in attributes.items():
        # Convert to list of strings
        if type(attr_values) == "string":
            values = [attr_values]
        elif type(attr_values) == "list":
            values = [str(v) for v in attr_values]
        else:
            values = [str(attr_values)]

        # Handle ordered numbering
        if ordered:
            new_values = []
            for idx, val in enumerate(values):
                clean_val = val
                if val.startswith("{") and "}" in val:
                    idx_brace = val.find("}")
                    clean_val = val[idx_brace + 1:]
                new_values.append("{" + str(idx) + "}" + clean_val)
            values = new_values

        if state == "present":
            for val in values:
                probe_cmd = ["ldapsearch", "-x", "-H", uri, "-b", dn, "(objectClass=*)", attr_name]
                probe_res = ctx.run(probe_cmd, mutates=False, ok_codes=[0, 32])
                # Collect existing values
                existing = []
                for line in probe_res.stdout.split("\n"):
                    if line.strip().startswith(attr_name + ":"):
                        existing.append(line.strip()[len(attr_name) + 1:].strip())
                if val not in existing:
                    lines.append("add: " + attr_name)
                    lines.append(attr_name + ": " + val)
                    lines.append("-")
                    modlist.append([0, attr_name, [val]])
        elif state == "absent":
            for val in values:
                filter_val = ldap_escape(val)
                probe_cmd = ["ldapsearch", "-x", "-H", uri, "-b", dn, "(" + attr_name + "=" + filter_val + ")", attr_name]
                probe_res = ctx.run(probe_cmd, mutates=False, ok_codes=[0, 32])
                if probe_res.rc == 0 and probe_res.stdout.find("dn:") != -1:
                    lines.append("delete: " + attr_name)
                    lines.append(attr_name + ": " + val)
                    lines.append("-")
                    modlist.append([1, attr_name, [val]])
        elif state == "exact":
            probe_cmd = ["ldapsearch", "-x", "-H", uri, "-b", dn, "(objectClass=*)", attr_name]
            probe_res = ctx.run(probe_cmd, mutates=False, ok_codes=[0, 32])
            current_values = []
            for line in probe_res.stdout.split("\n"):
                if line.strip().startswith(attr_name + ":"):
                    current_values.append(line.strip()[len(attr_name) + 1:].strip())
            current_set = set(current_values)
            target_set = set(values)
            if current_set != target_set:
                if len(target_set) == 0:
                    lines.append("delete: " + attr_name)
                    lines.append("-")
                    modlist.append([1, attr_name, None])
                else:
                    lines.append("replace: " + attr_name)
                    for val in values:
                        lines.append(attr_name + ": " + val)
                    lines.append("-")
                    modlist.append([2, attr_name, values])

    if len(modlist) == 0:
        return {"changed": False, "msg": "No changes needed", "modlist": []}

    if ctx.check_mode:
        return {"changed": True, "msg": "would apply changes", "modlist": modlist}

    ldif_content = "\n".join(lines) + "\n"

    # Use /tmp with unique name (no import needed, use ctx.run to generate)
    rand_part = ""
    for i in range(8):
        rand_part = rand_part + str((i * 7 + 3) % 10)  # deterministic placeholder
    ldif_path = "/tmp/ldap_attrs_" + rand_part + ".ldif"

    # Write LDIF file
    changed_write = ctx.file_write(ldif_path, ldif_content)

    # Run ldapmodify
    cmd = base_cmd + ["-f", ldif_path]
    res = ctx.run(cmd, mutates=True)

    # Clean up temp file
    ctx.run(["rm", "-f", ldif_path])

    if res.rc != 0:
        fail("ldapmodify failed: " + res.stderr)

    return {"changed": True, "msg": "Attributes modified successfully", "modlist": modlist}
