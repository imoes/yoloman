def main(ctx, params):
    username = params["username"]
    position = params.get("position", "")
    ou = params.get("ou", "")
    subpath = params.get("subpath", "cn=users")
    state = params.get("state", "present")
    update_password = params.get("update_password", "always")

    # Build container DN
    if position != "":
        container = position
    else:
        ou_part = "ou={}, ".format(ou) if ou != "" else ""
        subpath_part = "{}, ".format(subpath) if subpath != "" else ""
        ldap_base = ctx.facts().get("ldap_base_dn", "")
        container = subpath_part + ou_part + ldap_base

    user_dn = "uid={}, {}".format(username, container)

    # Check user existence via ldapsearch
    ldap_filter = "(&(objectClass=posixAccount)(uid={}))".format(username)
    res = ctx.run(["ldapsearch", "-x", "-b", container, ldap_filter, "dn"])
    if res.rc != 0:
        fail("ldapsearch failed: " + res.stderr)
    users = [line for line in res.stdout.splitlines() if line.startswith("dn:")]
    exists = len(users) > 0

    # Handle absent state
    if state == "absent":
        if not exists:
            return {"changed": False, "msg": "User " + username + " does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove user " + username}
        res = ctx.run(["udm", "users/user", "remove", "--dn", user_dn], mutates=True)
        if res.rc != 0:
            fail("Failed to remove user " + username + ": " + res.stderr)
        return {"changed": True, "msg": "Removed user " + username}

    # Present state: validate required params
    if not exists and (params.get("firstname") == None or params.get("lastname") == None or params.get("password") == None):
        fail("firstname, lastname, and password are required when creating a user")

    # Prepare user attributes
    attrs = {}
    if params.get("firstname") != None:
        attrs["firstname"] = params["firstname"]
    if params.get("lastname") != None:
        attrs["lastname"] = params["lastname"]
    if params.get("username") != None:
        attrs["username"] = params["username"]
    if params.get("password") != None:
        attrs["password"] = params["password"]
    if params.get("unixhome") != None:
        attrs["unixhome"] = params["unixhome"]
    if params.get("shell") != None:
        attrs["shell"] = params["shell"]
    if params.get("display_name") != None:
        attrs["displayName"] = params["display_name"]
    if params.get("department_number") != None:
        attrs["departmentNumber"] = params["department_number"]
    if params.get("home_share") != None:
        attrs["homeShare"] = params["home_share"]
    if params.get("home_share_path") != None:
        attrs["homeSharePath"] = params["home_share_path"]
    if params.get("home_telephone_number") != None and len(params["home_telephone_number"]) > 0:
        attrs["homeTelephoneNumber"] = params["home_telephone_number"]
    if params.get("employee_number") != None:
        attrs["employeeNumber"] = params["employee_number"]
    if params.get("employee_type") != None:
        attrs["employeeType"] = params["employee_type"]
    if params.get("mail_alternative_address") != None and len(params["mail_alternative_address"]) > 0:
        attrs["mailAlternativeAddress"] = params["mail_alternative_address"]
    if params.get("mail_home_server") != None:
        attrs["mailHomeServer"] = params["mail_home_server"]
    if params.get("mail_primary_address") != None:
        attrs["mailPrimaryAddress"] = params["mail_primary_address"]
    if params.get("mobile_telephone_number") != None and len(params["mobile_telephone_number"]) > 0:
        attrs["mobileTelephoneNumber"] = params["mobile_telephone_number"]
    if params.get("organisation") != None:
        attrs["organisation"] = params["organisation"]
    if params.get("overridePWHistory") != None:
        attrs["overridePWHistory"] = str(bool(params["overridePWHistory"]))
    if params.get("overridePWLength") != None:
        attrs["overridePWLength"] = str(bool(params["overridePWLength"]))
    if params.get("pager_telephonenumber") != None and len(params["pager_telephonenumber"]) > 0:
        attrs["pagerTelephonenumber"] = params["pager_telephonenumber"]
    if params.get("primary_group") != None:
        attrs["primaryGroup"] = params["primary_group"]
    if params.get("pwd_change_next_login") != None:
        attrs["pwdChangeNextLogin"] = params["pwd_change_next_login"]
    if params.get("room_number") != None:
        attrs["roomNumber"] = params["room_number"]
    if params.get("samba_privileges") != None and len(params["samba_privileges"]) > 0:
        attrs["sambaPrivileges"] = params["samba_privileges"]
    if params.get("samba_user_workstations") != None and len(params["samba_user_workstations"]) > 0:
        attrs["sambaUserWorkstations"] = params["samba_user_workstations"]
    if params.get("sambahome") != None:
        attrs["sambahome"] = params["sambahome"]
    if params.get("scriptpath") != None:
        attrs["scriptpath"] = params["scriptpath"]
    if params.get("serviceprovider") != None and len(params["serviceprovider"]) > 0:
        attrs["serviceprovider"] = params["serviceprovider"]
    if params.get("street") != None:
        attrs["street"] = params["street"]
    if params.get("title") != None:
        attrs["title"] = params["title"]
    if params.get("userexpiry") != None:
        attrs["userexpiry"] = params["userexpiry"]
    if params.get("city") != None:
        attrs["city"] = params["city"]
    if params.get("country") != None:
        attrs["country"] = params["country"]
    if params.get("gecos") != None:
        attrs["gecos"] = params["gecos"]
    if params.get("homedrive") != None:
        attrs["homedrive"] = params["homedrive"]
    if params.get("postcode") != None:
        attrs["postcode"] = params["postcode"]
    if params.get("profilepath") != None:
        attrs["profilepath"] = params["profilepath"]
    if params.get("birthday") != None:
        attrs["birthday"] = params["birthday"]
    if params.get("description") != None:
        attrs["description"] = params["description"]
    if params.get("phone") != None and len(params["phone"]) > 0:
        attrs["phone"] = params["phone"]
    if params.get("email") != None and len(params["email"]) > 0:
        attrs["e-mail"] = params["email"]
    if params.get("mobile_telephone_number") != None and len(params["mobile_telephone_number"]) > 0:
        attrs["mobileTelephoneNumber"] = params["mobile_telephone_number"]
    if params.get("pager_telephonenumber") != None and len(params["pager_telephonenumber"]) > 0:
        attrs["pagerTelephonenumber"] = params["pager_telephonenumber"]
    if params.get("home_telephone_number") != None and len(params["home_telephone_number"]) > 0:
        attrs["homeTelephoneNumber"] = params["home_telephone_number"]
    if params.get("secretary") != None and len(params["secretary"]) > 0:
        attrs["secretary"] = params["secretary"]

    # Special: displayName auto-computed if missing
    if "displayName" not in attrs and "firstname" in attrs and "lastname" in attrs:
        attrs["displayName"] = attrs["firstname"] + " " + attrs["lastname"]

    # Special: unixhome default
    if "unixhome" not in attrs:
        attrs["unixhome"] = "/home/" + username

    # Special: userexpiry default
    if "userexpiry" not in attrs:
        res = ctx.run(["date", "+%Y-%m-%d", "-d", "+365 days"], mutates=False)
        if res.rc != 0:
            fail("Failed to get future date")
        attrs["userexpiry"] = res.stdout.strip()

    # Special: primary_group default
    if "primaryGroup" not in attrs and not exists:
        ldap_base_for_group = container.split(",", 1)[1] if "," in container else ctx.facts().get("ldap_base_dn", "")
        default_group = "cn=Domain Users,cn=groups," + ldap_base_for_group
        attrs["primaryGroup"] = default_group

    changed = False
    msg = ""

    if not exists:
        # Create user
        if ctx.check_mode:
            return {"changed": True, "msg": "would create user " + username}
        cmd = ["udm", "users/user", "create", "--position", container]
        for k, v in attrs.items():
            if v != None and v != []:
                if type(v) == "list":
                    for item in v:
                        cmd.extend(["--set", k + "=" + str(item)])
                else:
                    cmd.extend(["--set", k + "=" + str(v)])
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("Failed to create user " + username + ": " + res.stderr)
        msg = "Created user " + username
        changed = True
    else:
        # Get current user attributes
        res = ctx.run(["udm", "users/user", "list", "--dn", user_dn], mutates=False)
        if res.rc != 0:
            fail("Failed to list user " + username + ": " + res.stderr)

        current = {}
        for line in res.stdout.splitlines():
            if line.find(":") >= 0:
                key = line.split(":", 1)[0].strip()
                val = line.split(":", 1)[1].strip()
                current[key] = val

        # Compare attributes
        for k, v in attrs.items():
            if k == "password":
                if update_password == "always":
                    changed = True
                continue
            cur_val = current.get(k)
            if cur_val == None:
                if v != None and str(v) != "":
                    changed = True
                    break
            else:
                def normalize_list(val):
                    if type(val) == "list":
                        return sorted([str(x).strip() for x in val])
                    if val == None or str(val) == "":
                        return []
                    parts = str(val).split()
                    if len(parts) > 1:
                        return sorted(parts)
                    return [str(val).strip()]
                new_val = normalize_list(v)
                old_val = normalize_list(cur_val)
                if new_val != old_val:
                    changed = True
                    break

        if not changed:
            return {"changed": False, "msg": "User " + username + " already up to date"}

        if ctx.check_mode:
            return {"changed": True, "msg": "would update user " + username}

        cmd = ["udm", "users/user", "modify", "--dn", user_dn]
        for k, v in attrs.items():
            if v != None and v != []:
                if type(v) == "list":
                    for item in v:
                        cmd.extend(["--set", k + "=" + str(item)])
                else:
                    cmd.extend(["--set", k + "=" + str(v)])
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("Failed to update user " + username + ": " + res.stderr)
        msg = "Updated user " + username
        changed = True

    # Handle group membership
    groups = params.get("groups", [])
    if len(groups) > 0:
        for g in groups:
            ldap_filter_group = "(&(objectClass=posixGroup)(cn=" + g + "))"
            res = ctx.run(["ldapsearch", "-x", "-b", container, ldap_filter_group, "dn"], mutates=False)
            if res.rc != 0:
                fail("ldapsearch for group " + g + " failed: " + res.stderr)
            dn_lines = [l for l in res.stdout.splitlines() if l.startswith("dn:")]
            for dn_line in dn_lines:
                group_dn = dn_line[3:].strip()
                res2 = ctx.run(["udm", "groups/group", "list", "--dn", group_dn], mutates=False)
                if res2.rc != 0:
                    fail("Failed to list group " + group_dn)
                users_in_group = []
                for line in res2.stdout.splitlines():
                    if line.startswith("users:"):
                        users_in_group = line.split(":", 1)[1].strip().split()
                if user_dn not in users_in_group:
                    if ctx.check_mode:
                        changed = True
                        continue
                    res3 = ctx.run(["udm", "groups/group", "modify", "--dn", group_dn, "--set", "users=" + user_dn], mutates=True)
                    if res3.rc != 0:
                        fail("Failed to add user " + username + " to group " + g + ": " + res3.stderr)
                    changed = True
                    msg = "Added user " + username + " to group " + g

    return {"changed": changed, "msg": msg}
