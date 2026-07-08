def main(ctx, params):
    script = params["script"]
    url = params.get("url", "http://localhost:8080")
    timeout = params.get("timeout", 10)
    args = params.get("args")
    user = params.get("user")
    password = params.get("password")
    validate_certs = params.get("validate_certs", True)

    # Template substitution if args provided
    if args != None:
        script_contents = script
        for key, value in args.items():
            script_contents = script_contents.replace("${" + key + "}", str(value))
            script_contents = script_contents.replace("$" + key + " ", str(value) + " ")
            script_contents = script_contents.replace("$" + key + "\n", str(value) + "\n")
            script_contents = script_contents.replace("$" + key + "\t", str(value) + "\t")
    else:
        script_contents = script

    # Auth header if user/password provided
    auth_header = ""
    if user != None:
        if password == None:
            fail("password required when user provided")
        auth_header = "Authorization: Basic " + str((user + ":" + password).encode("utf-8")).replace("b'", "").replace("'", "")

    # Check CSRF protection by fetching api/json
    curl_args = ["curl", "-s", "-k" if not validate_certs else "", "-H", "Accept: application/json", "-X", "GET", url + "/api/json"]
    res = ctx.run(curl_args, mutates=False)

    if res.rc != 0:
        fail("failed to reach Jenkins: " + res.stderr)

    use_crumbs = False
    for line in res.stdout.split("\n"):
        if '"useCrumbs"' in line and "true" in line:
            use_crumbs = True
            break

    # Get crumb if CSRF enabled
    crumb_header = ""
    crumb_value = ""
    if use_crumbs:
        curl_args = ["curl", "-s", "-k" if not validate_certs else "", "-H", "Accept: application/json", "-X", "GET", url + "/crumbIssuer/api/json"]
        res = ctx.run(curl_args, mutates=False)

        if res.rc != 0:
            fail("failed to get CSRF crumb: " + res.stderr)

        stdout = res.stdout
        lines = stdout.split("\n")
        for line in lines:
            if '"crumbRequestField"' in line:
                # Extract field name: find key and value between quotes
                parts = line.split(":")
                for part in parts:
                    part = part.strip().strip('"')
                    if part.startswith("Jenkins-Crumb") or "Crumb" in part:
                        crumb_header = part
                        break
            if '"crumb"' in line and crumb_header != "":
                parts = line.split(":")
                for part in parts:
                    part = part.strip().strip('"')
                    if len(part) > 0 and part[0].isalnum():
                        crumb_value = part
                        break

        if crumb_header == "" or crumb_value == "":
            fail("failed to parse CSRF crumb response")

    # Prepare curl command for script execution
    curl_args = [
        "curl", "-s", "-k" if not validate_certs else "", "-X", "POST", url + "/scriptText",
        "--data-urlencode", "script=" + script_contents,
        "-H", "Content-Type: application/x-www-form-urlencoded"
    ]

    if auth_header != "":
        idx = len(curl_args) - 1
        curl_args.insert(idx, "-H")
        curl_args.insert(idx + 1, auth_header)

    if crumb_header != "":
        idx = len(curl_args) - 1
        curl_args.insert(idx, "-H")
        curl_args.insert(idx + 1, crumb_header + ": " + crumb_value)

    res = ctx.run(curl_args, mutates=True)

    if res.skipped:
        return {"changed": True, "msg": "would execute script"}

    if res.rc != 0:
        fail("HTTP error " + str(res.rc) + ": " + res.stderr)

    result = res.stdout

    if "Exception:" in result and "at java.lang.Thread" in result:
        fail("script failed with stacktrace:\n" + result)

    return {"changed": True, "msg": "script executed successfully", "data": {"output": result}}
