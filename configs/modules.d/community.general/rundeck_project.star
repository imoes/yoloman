def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    api_token = params["api_token"]
    api_version = params.get("api_version", 39)
    url = params["url"]

    # Validate API version
    if api_version < 14:
        fail("API version should be at least 14")

    # Helper to make requests
    def make_request(method, endpoint, data=None):
        full_url = url.rstrip("/") + "/" + endpoint.lstrip("/")
        argv = ["curl", "-s", "-X", method, full_url]
        
        # Add headers
        headers = {
            "X-Rundeck-Auth-Token": api_token,
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
        for k, v in headers.items():
            argv.extend(["-H", k + ": " + v])
        
        # Add data if present
        if data != None:
            argv.extend(["-d", str(data)])
        
        res = ctx.run(argv, mutates=(method != "GET"))
        if res.rc != 0:
            fail("HTTP request failed: " + res.stderr)
        
        return res.stdout

    # Helper to check if project exists
    def project_exists():
        res = ctx.run(["curl", "-s", "-X", "GET", url.rstrip("/") + "/project/" + name, 
                      "-H", "X-Rundeck-Auth-Token: " + api_token,
                      "-H", "Content-Type: application/json",
                      "-H", "Accept: application/json"])
        return res.rc == 0

    # Handle state
    if state == "present":
        if project_exists():
            # Project already exists - no change
            return {"changed": False, "msg": "Project %s already exists" % name}
        
        # Check mode: simulate creation
        if ctx.check_mode:
            return {"changed": True, "msg": "would create project %s" % name}
        
        # Create project
        data = '{"name": "%s", "config": {}}' % name
        res = ctx.run(["curl", "-s", "-X", "POST", url.rstrip("/") + "/projects",
                      "-H", "X-Rundeck-Auth-Token: " + api_token,
                      "-H", "Content-Type: application/json",
                      "-H", "Accept: application/json",
                      "-d", data], mutates=True)
        if res.rc != 0:
            fail("Failed to create project %s: " + res.stderr)
        
        return {"changed": True, "msg": "Project %s created" % name}
    
    elif state == "absent":
        if not project_exists():
            # Project doesn't exist - no change
            return {"changed": False, "msg": "Project %s does not exist" % name}
        
        # Check mode: simulate deletion
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete project %s" % name}
        
        # Delete project
        res = ctx.run(["curl", "-s", "-X", "DELETE", url.rstrip("/") + "/project/" + name,
                      "-H", "X-Rundeck-Auth-Token: " + api_token,
                      "-H", "Content-Type: application/json",
                      "-H", "Accept: application/json"], mutates=True)
        if res.rc != 0:
            fail("Failed to delete project %s: " + res.stderr)
        
        return {"changed": True, "msg": "Project %s deleted" % name}
    
    else:
        fail("Unsupported state: " + state)
