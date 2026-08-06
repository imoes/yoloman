def main(ctx, params):
    user = params["user"]
    profile = params.get("profile")
    if profile != None:
        profile = profile.lower()
    resource_pool = params.get("resource_pool")
    if resource_pool != None:
        resource_pool = resource_pool.lower()
    password = params.get("password")
    expired = params.get("expired")
    ldap = params.get("ldap")
    roles_raw = params.get("roles")
    roles = []
    if roles_raw != None:
        roles = roles_raw.split(",")
        roles = [r for r in roles if r != ""]
    state = params.get("state", "present")
    locked = (state == "locked")
    db = params.get("db", "")

    cluster = params.get("cluster", "localhost")
    port = params.get("port", "5433")
    login_user = params.get("login_user", "dbadmin")
    login_password = params.get("login_password")

    # Verify isql is present
    res = ctx.run(["which", "isql"], mutates=False)
    if res.rc != 0:
        fail("vertica_user module requires unixODBC isql utility; isql not found")

    dsn = "Driver=Vertica;Server=%s;Port=%s;Database=%s;User=%s;Password=%s;ConnectionLoadBalance=true" % (cluster, port, db, login_user, login_password)

    def get_user_facts():
        facts = {}
        # Fetch user info via isql
        cmd = "SELECT u.user_name, u.is_locked, p.password, p.acctexpired, u.profile_name, u.resource_pool, u.all_roles, u.default_roles FROM users u JOIN password_auditor p ON p.user_id = u.user_id WHERE NOT u.is_super_user"
        sql_cmd = "echo '%s' | isql -v Vertica %s %s -b" % (cmd, login_user, login_password)
        res = ctx.run(["bash", "-c", sql_cmd], ok_codes=[0])
        if res.rc != 0:
            fail("Failed to query users: " + res.stderr)
        lines = res.stdout.splitlines()
        for line in lines:
            parts = line.split("\t")
            if len(parts) < 8:
                continue
            user_name = parts[0]
            is_locked = parts[1]
            password_db = parts[2]
            is_expired = parts[3]
            profile_name = parts[4]
            res_pool = parts[5]
            all_roles = parts[6]
            default_roles = parts[7]
            user_key = user_name.lower()
            roles_list = []
            if all_roles != None and all_roles != "":
                roles_list = [r.strip() for r in all_roles.split(",") if r.strip() != ""]
            default_roles_list = []
            if default_roles != None and default_roles != "":
                default_roles_list = [r.strip() for r in default_roles.split(",") if r.strip() != ""]
            facts[user_key] = {
                'name': user_name,
                'locked': is_locked,
                'password': password_db,
                'expired': is_expired,
                'profile': profile_name,
                'resource_pool': res_pool,
                'roles': roles_list,
                'default_roles': default_roles_list
            }
        return facts

    user_facts = get_user_facts()
    user_key = user.lower()
    user_exists = (user_key in user_facts)

    def run_sql(query):
        escaped_query = query.replace("'", "'\"'\"'")
        sql_cmd = "echo '%s' | isql -v Vertica %s %s -b" % (escaped_query, login_user, login_password)
        res = ctx.run(["bash", "-c", sql_cmd], ok_codes=[0])
        if res.rc != 0:
            fail("SQL command failed: " + query + " stderr: " + res.stderr)

    def user_matches():
        if not user_exists:
            return False
        fu = user_facts[user_key]
        if profile != None and fu.get('profile') != profile:
            return False
        if resource_pool != None and fu.get('resource_pool') != resource_pool:
            return False
        if locked == True and fu.get('locked') != "1":
            return False
        if locked == False and fu.get('locked') == "1":
            return False
        if password != None and fu.get('password') != password:
            return False
        if expired != None:
            if (expired == True and fu.get('expired') != "1") or (expired == False and fu.get('expired') == "1"):
                return False
        if ldap != None:
            if (ldap == True and fu.get('expired') != "1") or (ldap == False and fu.get('expired') == "1"):
                return False
        if len(roles) > 0:
            if sorted(roles) != sorted(fu.get('roles', [])) or sorted(roles) != sorted(fu.get('default_roles', [])):
                return False
        return True

    if ctx.check_mode:
        if state == "absent":
            changed = user_exists
        elif state in ["present", "locked"]:
            changed = not user_matches()
        else:
            fail("unsupported state: " + state)
        return {"changed": changed, "msg": "check mode, no changes made"}

    if state == "absent":
        if not user_exists:
            return {"changed": False, "msg": "user %s does not exist" % user}
        roles_to_revoke = user_facts[user_key].get('roles', [])
        if len(roles_to_revoke) > 0:
            run_sql("REVOKE " + ",".join(roles_to_revoke) + " FROM " + user)
        cmd = "DROP USER " + user
        sql_cmd = "echo '%s' | isql -v Vertica %s %s -b" % (cmd, login_user, login_password)
        res = ctx.run(["bash", "-c", sql_cmd], ok_codes=[0])
        if res.rc != 0:
            fail("failed to drop user " + user + ": " + res.stderr)
        return {"changed": True, "msg": "user %s removed" % user}

    elif state in ["present", "locked"]:
        if not user_exists:
            qparts = ["CREATE USER " + user]
            if locked:
                qparts.append("ACCOUNT LOCK")
            if password != None:
                qparts.append("IDENTIFIED BY '%s'" % password)
            elif ldap:
                qparts.append("IDENTIFIED BY '$ldap$'")
            if expired or ldap:
                qparts.append("PASSWORD EXPIRE")
            if profile != None:
                qparts.append("PROFILE %s" % profile)
            if resource_pool != None:
                qparts.append("RESOURCE POOL %s" % resource_pool)
            run_sql(" ".join(qparts))
            if resource_pool != None and resource_pool != "general":
                run_sql("GRANT USAGE ON RESOURCE POOL %s TO %s" % (resource_pool, user))
            if len(roles) > 0:
                run_sql("GRANT " + ",".join(roles) + " TO " + user)
                run_sql("ALTER USER " + user + " DEFAULT ROLE " + ",".join(roles))
            return {"changed": True, "msg": "user %s created" % user}

        else:
            fu = user_facts[user_key]
            changed = False
            qparts = ["ALTER USER " + user]

            if locked == True and fu.get('locked') != "1":
                qparts.append("ACCOUNT LOCK")
                changed = True
            elif locked == False and fu.get('locked') == "1":
                qparts.append("ACCOUNT UNLOCK")
                changed = True

            if password != None and fu.get('password') != password:
                qparts.append("IDENTIFIED BY '%s'" % password)
                changed = True

            if ldap != None:
                if (ldap == True and fu.get('expired') != "1"):
                    qparts.append("PASSWORD EXPIRE")
                    changed = True
                elif (ldap == False and fu.get('expired') == "1"):
                    fail("Unexpiring user password is not supported by Vertica.")
            elif expired != None:
                if expired == True and fu.get('expired') != "1":
                    qparts.append("PASSWORD EXPIRE")
                    changed = True
                elif expired == False and fu.get('expired') == "1":
                    fail("Unexpiring user password is not supported by Vertica.")

            if profile != None and fu.get('profile') != profile:
                qparts.append("PROFILE %s" % profile)
                changed = True

            if resource_pool != None and fu.get('resource_pool') != resource_pool:
                old_pool = fu.get('resource_pool')
                if old_pool != None and old_pool != "general":
                    qparts.append("REVOKE USAGE ON RESOURCE POOL %s FROM %s" % (old_pool, user))
                if resource_pool != "general":
                    qparts.append("RESOURCE POOL %s" % resource_pool)
                changed = True

            if changed:
                run_sql(" ".join(qparts))

            if len(roles) > 0:
                cur_all = fu.get('roles', [])
                cur_def = fu.get('default_roles', [])
                if sorted(roles) != sorted(cur_all) or sorted(roles) != sorted(cur_def):
                    to_revoke = [r for r in cur_all if r not in roles]
                    if len(to_revoke) > 0:
                        run_sql("REVOKE " + ",".join(to_revoke) + " FROM " + user)
                    to_grant = [r for r in roles if r not in cur_all]
                    if len(to_grant) > 0:
                        run_sql("GRANT " + ",".join(to_grant) + " TO " + user)
                    run_sql("ALTER USER " + user + " DEFAULT ROLE " + ",".join(roles))
                    changed = True

            if changed:
                return {"changed": True, "msg": "user %s updated" % user}
            else:
                return {"changed": False, "msg": "user %s already matches desired state" % user}

    else:
        fail("unsupported state: " + state)
