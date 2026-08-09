def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    user = params.get("user")
    password = params.get("password")
    token = params.get("token")
    url = params.get("url", "http://localhost:8080")
    build_number = params.get("build_number")
    args_dict = params.get("args")
    detach = params.get("detach", False)
    time_between_checks = params.get("time_between_checks", 10)

    # Authentication validation
    if password != None and token != None:
        fail("password and token are mutually exclusive")

    # State-specific validation
    if state in ("absent", "stopped") and build_number == None:
        fail("build_number is required for state '" + state + "'")

    # Build auth string (no credentials = anonymous)
    auth = ""
    if user != None:
        if password != None:
            auth = user + ":" + password + "@"
        elif token != None:
            auth = user + ":" + token + "@"
        else:
            auth = user + "@"

    base_url = url.rstrip("/")
    job_url = base_url + "/job/" + name + "/"

    # Helper: run jenkins API call (POST/GET via curl)
    def jenkins_post(path, data=None):
        headers = []
        if auth != "":
            headers = ["-u", auth.rstrip("@")]
        argv = ["curl", "-s", "-X", "POST"] + headers + [path]
        if data != None:
            argv.extend(["--data-urlencode", "json=" + data])
        res = ctx.run(argv, mutates=True)
        if res.skipped:
            return None
        if res.rc != 0:
            fail("Jenkins request failed (" + path + "): " + res.stderr)
        return res.stdout

    def jenkins_get(path):
        headers = []
        if auth != "":
            headers = ["-u", auth.rstrip("@")]
        res = ctx.run(["curl", "-s"] + headers + [path], mutates=False)
        if res.skipped:
            return ""
        if res.rc != 0:
            fail("Jenkins GET failed (" + path + "): " + res.stderr)
        return res.stdout

    # State: present (trigger build)
    if state == "present":
        # Get nextBuildNumber
        job_info_url = base_url + "/job/" + name + "/api/json?tree=nextBuildNumber"
        info = jenkins_get(job_info_url)
        # Simple parsing without regex or try/except
        next_bn = -1
        if '"nextBuildNumber":' in info:
            parts = info.split('"nextBuildNumber":')
            if len(parts) > 1:
                num_str = parts[1].split(",")[0].strip()
                if num_str.isdigit():
                    next_bn = int(num_str)

        if next_bn == -1:
            fail("Unable to parse nextBuildNumber from job info")

        # Trigger build
        build_url = base_url + "/job/" + name + "/build"
        post_data = None
        if args_dict != None:
            # Simple JSON serialization (no external modules)
            items = []
            for k, v in args_dict.items():
                items.append('"' + k + '":' + '"' + str(v) + '"')
            post_data = "{" + ",".join(items) + "}"

        jenkins_post(build_url, data=post_data)

        if detach:
            return {
                "changed": True,
                "msg": "build triggered (detached)",
                "data": {
                    "build_number": next_bn,
                    "detached": True
                }
            }

        # Wait for build completion
        build_url_full = base_url + "/job/" + name + "/" + str(next_bn) + "/api/json"
        attempts = 0
        max_attempts = 600  # ~1 hour max (600 * 6s)
        while attempts < max_attempts:
            ctx.run(["sleep", str(time_between_checks)], mutates=False)
            info = jenkins_get(build_url_full)
            # Check building status and result
            building = '"building":true' in info
            if not building and '"result":"' in info:
                # Extract result
                result_str = info.split('"result":"')[1].split('"')[0]
                return {
                    "changed": True,
                    "msg": "build finished with result: " + result_str,
                    "data": {"build_number": next_bn, "result": result_str}
                }
            if attempts >= max_attempts:
                fail("Build timed out (max wait exceeded)")
            attempts = attempts + 1

        fail("Build timed out (max wait exceeded)")

    # State: absent (delete build)
    elif state == "absent":
        # Check if build exists
        build_url = base_url + "/job/" + name + "/" + str(build_number) + "/api/json"
        info = jenkins_get(build_url)

        if '"result":"ABSENT"' in info or '"error"' in info.lower():
            return {"changed": False, "msg": "build does not exist", "data": {"build_number": build_number}}

        # Delete build
        delete_url = base_url + "/job/" + name + "/" + str(build_number) + "/doDelete"
        jenkins_post(delete_url)

        return {
            "changed": True,
            "msg": "build " + str(build_number) + " deleted",
            "data": {"build_number": build_number}
        }

    # State: stopped (stop running build)
    elif state == "stopped":
        # Check build info
        build_url = base_url + "/job/" + name + "/" + str(build_number) + "/api/json"
        info = jenkins_get(build_url)

        if '"building":false' in info and '"result":' in info:
            return {
                "changed": False,
                "msg": "build " + str(build_number) + " is not running",
                "data": {"build_number": build_number}
            }

        # Stop build
        stop_url = base_url + "/job/" + name + "/" + str(build_number) + "/stop"
        jenkins_post(stop_url)

        return {
            "changed": True,
            "msg": "build " + str(build_number) + " stop requested",
            "data": {"build_number": build_number}
        }

    fail("unreachable state")
