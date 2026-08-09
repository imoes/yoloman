def main(ctx, params):
    user_name = params["user_name"]
    state = params.get("state", "present")
    user_password = params.get("user_password")
    admin = params.get("admin", False)
    grants = params.get("grants")
    hostname = params.get("hostname", "localhost")
    port = params.get("port", 8086)
    ssl = params.get("ssl", False)
    username = params.get("username", "root")
    password = params.get("password", "root")
    path = params.get("path", "")
    validate_certs = params.get("validate_certs", True)

    protocol = "https" if ssl else "http"
    base_url = protocol + "://" + hostname + ":" + str(port)
    if path != "" and not path.startswith("/"):
        path = "/" + path
    url = base_url + path

    auth_header = "Basic " + (username + ":" + password).encode("utf-8").hex()

    def http_get(endpoint):
        res = ctx.run(["curl", "-sSf", "-X", "GET", url + endpoint, "-H", "Authorization: " + auth_header] +
                      ([] if validate_certs else ["-k"]), mutates=False)
        if res.rc != 0:
            fail("GET " + endpoint + " failed: " + res.stderr)
        return res.stdout

    def http_post(endpoint, data):
        res = ctx.run(["curl", "-sSf", "-X", "POST", url + endpoint,
                       "-H", "Authorization: " + auth_header,
                       "-H", "Content-Type: application/json",
                       "-d", data] +
                      ([] if validate_certs else ["-k"]), mutates=False)
        if res.rc != 0:
            fail("POST " + endpoint + " failed: " + res.stderr)
        return res.stdout

    def http_delete(endpoint):
        res = ctx.run(["curl", "-sSf", "-X", "DELETE", url + endpoint,
                       "-H", "Authorization: " + auth_header] +
                      ([] if validate_certs else ["-k"]), mutates=False)
        if res.rc != 0 and "user not found" not in res.stderr:
            fail("DELETE " + endpoint + " failed: " + res.stderr)
        return res.stdout

    def get_users():
        raw = http_get("/users")
        return raw.splitlines()

    def find_user(name):
        for line in get_users():
            line = line.strip()
            if line == "":
                continue
            user_idx = line.find('"user"')
            if user_idx == -1:
                continue
            user_start = line.find('"', user_idx + 6) + 1
            user_end = line.find('"', user_start)
            if user_end == -1:
                continue
            user_val = line[user_start:user_end]
            if user_val == name:
                admin_idx = line.find('"admin"')
                admin_start = line.find(":", admin_idx) + 1
                admin_val = line[admin_start:].strip()
                if admin_val.startswith("true"):
                    return {"user": name, "admin": True}
                elif admin_val.startswith("false"):
                    return {"user": name, "admin": False}
                else:
                    if admin_val == "1":
                        return {"user": name, "admin": True}
                    else:
                        return {"user": name, "admin": False}
        return None

    def check_password():
        http_post("/query", '{"q":"SHOW DATABASES"}')
        return True

    def set_password():
        http_post("/users/" + user_name, '{"password":"%s"}' % user_password)

    def create_user():
        payload = '{"name":"%s","password":"%s","admin":%s}' % (user_name, user_password if user_password else "", "true" if admin else "false")
        http_post("/users", payload)

    def drop_user():
        http_delete("/users/" + user_name)

    def get_privileges():
        raw = http_post("/query", '{"q":"SHOW PRIVILEGES FOR \\"%s\\""}' % user_name)
        lines = raw.splitlines()
        privileges = []
        for line in lines:
            if line.strip() == "" or not line.startswith('{"results":[{"series"'):
                continue
            if '"name":' in line:
                db_start = line.find('"name":"') + 8
                db_end = line.find('"', db_start)
                if db_end == -1:
                    continue
                db_name = line[db_start:db_end]
                priv_start = line.find('"privileges":"') + 14
                priv_end = line.find('"', priv_start)
                if priv_end == -1:
                    continue
                priv_val = line[priv_start:priv_end]
                privileges.append({"database": db_name, "privilege": priv_val})
        return privileges

    def grant_privilege(db, priv):
        http_post("/query", '{"q":"GRANT %s ON \\"%s\\" TO \\"%s\\""}' % (priv, db, user_name))

    def revoke_privilege(db, priv):
        http_post("/query", '{"q":"REVOKE %s ON \\"%s\\" FROM \\"%s\\""}' % (priv, db, user_name))

    def grant_admin():
        http_post("/query", '{"q":"GRANT ALL PRIVILEGES TO \\"%s\\""}' % user_name)

    def revoke_admin():
        http_post("/query", '{"q":"REVOKE ALL PRIVILEGES FROM \\"%s\\""}' % user_name)

    changed = False
    msg = ""

    user = find_user(user_name)

    if state == "present":
        if user == None:
            if not ctx.check_mode:
                create_user()
            changed = True
            msg = "created user " + user_name
        else:
            if user_password != None and not check_password():
                if not ctx.check_mode:
                    set_password()
                changed = True
                msg = "updated password for user " + user_name

            if admin == True and user["admin"] == False:
                if not ctx.check_mode:
                    grant_admin()
                changed = True
                msg = "granted admin role to user " + user_name
            elif admin == False and user["admin"] == True:
                if not ctx.check_mode:
                    revoke_admin()
                changed = True
                msg = "revoked admin role from user " + user_name

        if grants != None:
            current = get_privileges()
            norm_current = []
            for g in current:
                norm_current.append({
                    "database": g["database"],
                    "privilege": "ALL" if g["privilege"] == "ALL PRIVILEGES" else g["privilege"]
                })

            desired = []
            for g in grants:
                if g != None:
                    desired.append({
                        "database": g["database"],
                        "privilege": g["privilege"]
                    })

            for g in norm_current:
                if g not in desired:
                    if not ctx.check_mode:
                        revoke_privilege(g["database"], g["privilege"])
                    changed = True
                    msg = "revoked privilege " + g["privilege"] + " on " + g["database"] + " from user " + user_name

            for g in desired:
                if g not in norm_current:
                    if not ctx.check_mode:
                        grant_privilege(g["database"], g["privilege"])
                    changed = True
                    msg = "granted privilege " + g["privilege"] + " on " + g["database"] + " to user " + user_name

        if not changed:
            msg = "user " + user_name + " already exists"

    elif state == "absent":
        if user != None:
            if not ctx.check_mode:
                drop_user()
            changed = True
            msg = "deleted user " + user_name
        else:
            changed = False
            msg = "user " + user_name + " does not exist"

    return {"changed": changed, "msg": msg}
