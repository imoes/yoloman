def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    ou = params["ou"]

    # Construct container DN
    base_dn = ctx.facts().get("base_dn", "")
    container = "cn=shares,ou=" + ou + "," + base_dn
    dn = "cn=" + name + "," + container

    # Check if share exists
    res = ctx.run([
        "univention-ldapsearch",
        "-b", container,
        "-LL", "(&(objectClass=univentionShare)(cn=" + name + "))",
        "cn"
    ], mutates=False)
    if res.rc != 0:
        fail("Failed to search for existing share: " + res.stderr)
    exists = res.stdout.strip() != ""

    changed = False
    diff = None

    if state == "present":
        # Required params for present
        for req in ["path", "host", "sambaName"]:
            if not params.get(req):
                fail("Missing required parameter '" + req + "' when state=present")

        # Prepare parameter mapping and boolean conversions
        umc_params = dict(params)
        # Map aliases to primary keys for UMC
        samba_name = umc_params.get("samba_name") or umc_params.get("sambaName")
        umc_params["printablename"] = name + " (" + umc_params["host"] + ")"
        umc_params["samba_name"] = samba_name

        # Convert bools to string for UMC
        for key in umc_params:
            val = umc_params[key]
            if type(val) == "bool":
                umc_params[key] = "1" if val else "0"

        # Prepare diff (simplified)
        diff_lines = []
        if exists:
            # Get current values by running get command
            get_res = ctx.run([
                "univention-directory-manager",
                "shares/share",
                "get",
                "--dn", dn
            ], mutates=False)
            if get_res.rc == 0:
                current = {}
                for line in get_res.stdout.splitlines():
                    if line.find(":") >= 0:
                        parts = line.split(":", 1)
                        k = parts[0].strip()
                        v = parts[1].strip() if len(parts) > 1 else ""
                        current[k] = v
                # Compute diff (only keys that differ)
                for k in umc_params:
                    if k not in ["host", "ou", "name", "state", "path", "samba_name", "sambaName", "printablename"]:
                        cv = current.get(k, "")
                        pv = umc_params[k]
                        if str(cv) != str(pv):
                            diff_lines.append("- " + k + ": " + str(cv))
                            diff_lines.append("+ " + k + ": " + str(pv))
                diff = "\n".join(diff_lines) if diff_lines else None

        if not exists or diff:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create/edit share " + name}
            else:
                if not exists:
                    # Create new share
                    cmd = [
                        "univention-directory-manager",
                        "shares/share",
                        "create",
                        "--position", container
                    ]
                    for k in umc_params:
                        if k not in ["host", "ou", "name", "state", "path", "samba_name", "sambaName", "printablename"]:
                            val = umc_params[k]
                            if type(val) == "list":
                                for v in val:
                                    cmd.extend(["--set", k + "=" + str(v)])
                            elif type(val) == "dict":
                                continue
                            else:
                                cmd.extend(["--set", k + "=" + str(val)])
                    cmd.extend(["--set", "cn=" + name])
                    cmd.extend(["--set", "sharePath=" + umc_params["path"]])
                    cmd.extend(["--set", "shareHost=" + umc_params["host"]])
                    cmd.extend(["--set", "sambaName=" + umc_params["samba_name"]])

                    res = ctx.run(cmd, mutates=True)
                    if res.rc != 0:
                        fail("Failed to create share: " + res.stderr)
                    changed = True
                else:
                    # Modify existing share
                    cmd = [
                        "univention-directory-manager",
                        "shares/share",
                        "modify",
                        "--dn", dn
                    ]
                    for k in umc_params:
                        if k not in ["host", "ou", "name", "state", "path", "samba_name", "sambaName", "printablename"]:
                            val = umc_params[k]
                            if type(val) == "list":
                                for v in val:
                                    cmd.extend(["--set", k + "=" + str(v)])
                            elif type(val) == "dict":
                                continue
                            else:
                                cmd.extend(["--set", k + "=" + str(val)])
                    res = ctx.run(cmd, mutates=True)
                    if res.rc != 0:
                        fail("Failed to modify share: " + res.stderr)
                    changed = True

    elif state == "absent" and exists:
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete share " + name}
        else:
            res = ctx.run([
                "univention-directory-manager",
                "shares/share",
                "remove",
                "--dn", dn
            ], mutates=True)
            if res.rc != 0:
                fail("Failed to remove share: " + res.stderr)
            changed = True

    msg = "unchanged"
    if changed:
        if state == "present":
            msg = "created" if not exists else "modified"
        elif state == "absent":
            msg = "removed"
    return {"changed": changed, "msg": msg + " share " + name, "diff": diff}
