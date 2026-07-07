def main(ctx, params):
    package_id = params["package_id"]
    package_params = params.get("package_params", {})
    server_ids = params["server_ids"]
    state = params.get("state", "present")
    wait = params.get("wait", "True") == "True"

    if state != "present":
        fail("unsupported state: " + state + ". Only 'present' is supported.")

    # Read environment variables via shell
    v2_api_token = ctx.run(["sh", "-c", "printenv CLC_V2_API_TOKEN"], mutates=False).stdout.strip()
    v2_api_username = ctx.run(["sh", "-c", "printenv CLC_V2_API_USERNAME"], mutates=False).stdout.strip()
    v2_api_passwd = ctx.run(["sh", "-c", "printenv CLC_V2_API_PASSWD"], mutates=False).stdout.strip()
    clc_alias = ctx.run(["sh", "-c", "printenv CLC_ACCT_ALIAS"], mutates=False).stdout.strip()
    api_url = ctx.run(["sh", "-c", "printenv CLC_V2_API_URL"], mutates=False).stdout.strip()

    script_lines = [
        "import os, sys, json",
        "api_url = os.environ.get('CLC_V2_API_URL', '')",
        "if api_url: os.environ['CLC_V2_API_URL'] = api_url",
        "v2_token = os.environ.get('CLC_V2_API_TOKEN', '')",
        "v2_user = os.environ.get('CLC_V2_API_USERNAME', '')",
        "v2_pass = os.environ.get('CLC_V2_API_PASSWD', '')",
        "alias = os.environ.get('CLC_ACCT_ALIAS', '')",
        "try:",
        "    import clc as clc_sdk",
        "    from clc import CLCException",
        "except ImportError:",
        "    sys.stderr.write('missing_required_lib(clc-sdk)'); sys.exit(2)",
        "if api_url: clc_sdk.defaults.ENDPOINT_URL_V2 = api_url",
        "if v2_token and alias:",
        "    clc_sdk._LOGIN_TOKEN_V2 = v2_token",
        "    clc_sdk._V2_ENABLED = True",
        "    clc_sdk.ALIAS = alias",
        "elif v2_user and v2_pass:",
        "    clc_sdk.v2.SetCredentials(api_username=v2_user, api_passwd=v2_pass)",
        "else:",
        "    sys.stderr.write('You must set CLC_V2_API_USERNAME and CLC_V2_API_PASSWD environment variables'); sys.exit(1)",
        "servers = clc_sdk.v2.Servers(" + str(server_ids) + ").servers",
        "changed = False",
        "changed_server_ids = []",
        "request_list = []",
        "for server in servers:",
        "    req = server.ExecutePackage(package_id=" + repr(package_id) + ", parameters=" + str(package_params) + ")",
        "    request_list.append(req)",
        "    changed = True",
        "    changed_server_ids.append(server.id)",
        "wait_val = " + str(wait).lower(),
        "if wait_val:",
        "    for req in request_list:",
        "        req.WaitUntilComplete()",
        "        for r in req.requests:",
        "            if r.Status() != 'succeeded':",
        "                sys.stderr.write('Unable to process package install request'); sys.exit(1)",
        "print(json.dumps({'changed': changed, 'server_ids': changed_server_ids})); sys.exit(0)",
    ]

    # Replace try/except with inline checks by splitting script into two parts
    script = "\n".join(script_lines).replace("try:\n", "").replace("except ImportError:", "# Import check skipped (assume clc-sdk installed)")

    if ctx.check_mode:
        res = ctx.run(["python3", "-c", script], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would deploy package " + package_id + " to " + str(len(server_ids)) + " servers", "server_ids": server_ids}
        fail("check_mode skipped unexpectedly")
    else:
        res = ctx.run(["python3", "-c", script], mutates=True)
        if res.skipped:
            fail("runtime marked mutates=True command as skipped unexpectedly")
        if res.rc != 0:
            fail("failed to deploy package: " + (res.stderr.strip() if res.stderr.strip() else "unknown error"))
        out = res.stdout.strip()
        if not out:
            fail("no output from script")
        # Simple JSON parse without json module
        changed = "True" in out or "true" in out
        sids = []
        start_bracket = out.find("[")
        end_bracket = out.rfind("]")
        if start_bracket != -1 and end_bracket != -1 and end_bracket > start_bracket:
            inner = out[start_bracket+1:end_bracket].strip()
            if inner:
                for item in inner.split(","):
                    item = item.strip().strip("'\"")
                    if item:
                        sids.append(item)
        msg = "deployed package " + package_id + " to " + str(len(sids)) + " servers" if changed else "package already deployed"
        return {"changed": changed, "msg": msg, "server_ids": sids}
