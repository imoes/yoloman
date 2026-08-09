def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    force_install = params.get("force_install", False)
    appliance = params.get("appliance", "backend")
    rack = params.get("rack", 0)
    rank = params.get("rank", 0)
    stacki_endpoint = params["stacki_endpoint"]
    stacki_user = params["stacki_user"]
    stacki_password = params["stacki_password"]

    # Authentication: get initial CSRF token
    auth_url = stacki_endpoint + "/login"
    auth_creds = "USERNAME=" + stacki_user + "&PASSWORD=" + stacki_password
    res = ctx.run(["curl", "-s", "-c", "-", "-b", "-", "-X", "GET", stacki_endpoint], mutates=False)
    if res.rc != 0:
        fail("failed to get initial CSRF: " + res.stderr)

    headers = []
    cookie = ""
    for line in res.stdout.splitlines():
        if "Set-Cookie:" in line:
            parts = line.split("Set-Cookie:")[1].strip().split(";")
            for part in parts:
                if "csrftoken=" in part:
                    token = part.strip().split("csrftoken=")[1]
                    headers.append("X-CSRFToken: " + token)
                    headers.append("csrftoken: " + token)
                    cookie = "csrftoken=" + token + "; "
                elif "sessionid=" in part:
                    sid = part.strip().split("sessionid=")[1]
                    cookie += "sessionid=" + sid + "; "
    if not cookie:
        fail("failed to extract session cookie")
    headers.append("Cookie: " + cookie)

    # Login
    login_res = ctx.run(["curl", "-s", "-c", "-", "-b", "-", "-X", "POST", "-H", "Content-type: application/x-www-form-urlencoded",
                         "-d", auth_creds, auth_url], mutates=False)
    if login_res.rc != 0:
        fail("login failed: " + login_res.stderr)

    # Update cookie from login response
    for line in login_res.stdout.splitlines():
        if "Set-Cookie:" in line:
            parts = line.split("Set-Cookie:")[1].strip().split(";")
            for part in parts:
                if "sessionid=" in part:
                    sid = part.strip().split("sessionid=")[1]
                    cookie = "csrftoken=" + cookie.split("csrftoken=")[1].split(";")[0] + "; sessionid=" + sid + "; "
    headers = headers if headers else []
    headers.append("Cookie: " + cookie)
    headers = [h for h in headers if "sessionid=" not in h or "csrftoken=" not in h]  # avoid dupes

    # Check if host exists
    list_cmd = ["curl", "-s", "-b", "-", "-H", "Content-type: application/json", "-d", '{"cmd": "list host"}',
                stacki_endpoint]
    list_res = ctx.run(list_cmd + ["-H", headers[0]] if headers else list_cmd, mutates=False)
    if list_res.rc != 0:
        fail("failed to list hosts: " + list_res.stderr)
    host_exists = name in list_res.stdout

    # Handle state
    result = {"changed": False, "stdout": "", "stdout_lines": []}

    if state == "present":
        if host_exists:
            if force_install:
                # Force install
                set_boot_cmd = ["curl", "-s", "-b", "-", "-H", "Content-type: application/json",
                                "-d", '{"cmd": "set host boot ' + name + ' action=install"}',
                                stacki_endpoint]
                set_boot_res = ctx.run(set_boot_cmd, mutates=True)
                if set_boot_res.skipped:
                    return {"changed": True, "msg": "would force install host " + name}
                if set_boot_res.rc != 0:
                    fail("failed to set boot action: " + set_boot_res.stderr)

                # Sync
                sync1 = ctx.run(["curl", "-s", "-b", "-", "-H", "Content-type: application/json",
                                 "-d", '{"cmd": "sync config"}', stacki_endpoint], mutates=True)
                sync2 = ctx.run(["curl", "-s", "-b", "-", "-H", "Content-type: application/json",
                                 "-d", '{"cmd": "sync host config"}', stacki_endpoint], mutates=True)
                if sync1.skipped or sync2.skipped:
                    return {"changed": True, "msg": "would force install and sync host " + name}
                result["changed"] = True
                result["stdout"] = "api call successful"
            else:
                result["stdout"] = name + " already exists. Set 'force_install' to true to bootstrap"
        else:
            # Add host — check required params
            required = ["appliance", "rack", "rank"]
            missing = [p for p in required if params.get(p) == None]
            if missing:
                fail("missing required arguments: " + str(missing))

            add_cmd = ["curl", "-s", "-b", "-", "-H", "Content-type: application/json",
                       "-d", '{"cmd": "add host ' + name + ' rack=' + str(rack) + ' rank=' + str(rank) + ' appliance=' + appliance + '"}',
                       stacki_endpoint]
            add_res = ctx.run(add_cmd, mutates=True)
            if add_res.skipped:
                return {"changed": True, "msg": "would add host " + name}
            if add_res.rc != 0:
                fail("failed to add host: " + add_res.stderr)

            # Sync
            sync1 = ctx.run(["curl", "-s", "-b", "-", "-H", "Content-type: application/json",
                             "-d", '{"cmd": "sync config"}', stacki_endpoint], mutates=True)
            sync2 = ctx.run(["curl", "-s", "-b", "-", "-H", "Content-type: application/json",
                             "-d", '{"cmd": "sync host config"}', stacki_endpoint], mutates=True)
            if sync1.skipped or sync2.skipped:
                return {"changed": True, "msg": "would add host and sync " + name}
            result["changed"] = True
            result["stdout"] = "api call successful"
    elif state == "absent":
        if host_exists:
            rm_cmd = ["curl", "-s", "-b", "-", "-H", "Content-type: application/json",
                      "-d", '{"cmd": "remove host ' + name + '"}', stacki_endpoint]
            rm_res = ctx.run(rm_cmd, mutates=True)
            if rm_res.skipped:
                return {"changed": True, "msg": "would remove host " + name}
            if rm_res.rc != 0:
                fail("failed to remove host: " + rm_res.stderr)

            sync1 = ctx.run(["curl", "-s", "-b", "-", "-H", "Content-type: application/json",
                             "-d", '{"cmd": "sync config"}', stacki_endpoint], mutates=True)
            sync2 = ctx.run(["curl", "-s", "-b", "-", "-H", "Content-type: application/json",
                             "-d", '{"cmd": "sync host config"}', stacki_endpoint], mutates=True)
            if sync1.skipped or sync2.skipped:
                return {"changed": True, "msg": "would remove host and sync " + name}
            result["changed"] = True
            result["stdout"] = "api call successful"
        else:
            result["stdout"] = name + " does not exist"

    result["stdout_lines"] = result["stdout"].splitlines()
    result["msg"] = "api call successful" if result["changed"] else result["stdout"]
    return result
