def main(ctx, params):
    # Required parameters
    name = params["name"]
    domain = params["domain"]
    identity_endpoint = params["identity_endpoint"]
    project = params["project"]
    user = params["user"]
    password = params["password"]
    region = params.get("region")
    state = params.get("state", "present")
    display_name = params.get("display_name")
    topic_id = params.get("id")

    # Build SMN base URL: assume region is required and provided
    if region == None:
        fail("region is required for SMN operations")

    base_url = identity_endpoint.rstrip("/") + "/v2/" + project["project_id"] + "/notifications/topics"
    smn_endpoint = base_url

    # Helper to construct topic URL
    def topic_url(tid):
        return base_url + "/" + tid

    # Auth: we'll assume keystone v3 token is obtained elsewhere;
    # for this translation, ctx.run will use --user/--password/--domain/--project
    # but we simulate a token-based request. Since Starlark has no HTTP client,
    # we rely on an external tool: assume `hwc` CLI is available (common in Huawei environments)
    def smn_request(method, path, data=None):
        # Build hwc command for SMN requests
        cmd = [
            "hwc", "smn", "request",
            "--identity-endpoint", identity_endpoint,
            "--domain", domain,
            "--project", project,
            "--region", region,
            "--user", user,
            "--password", password,
            method,
            path
        ]
        if data != None:
            # Convert dict to JSON string manually (no json module)
            # Simple escaping for key/values with letters/digits/underscore/hyphen/space
            # This is fragile but acceptable in controlled environments
            json_str = "{"
            items = sorted(data.items())
            for i, (k, v) in enumerate(items):
                if i > 0:
                    json_str += ","
                # Escape string values
                escaped = str(v).replace("\\", "\\\\").replace('"', '\\"')
                json_str += '"' + k + '":" ' + escaped + '"'
            json_str += "}"
            cmd.append(json_str)
        res = ctx.run(cmd, mutates=(method in ["POST", "PUT", "DELETE"]))
        if res.skipped:
            return None
        if res.rc != 0:
            fail("SMN request failed: " + res.stderr)
        # Parse JSON manually: simple case: extract known keys
        return parse_simple_json(res.stdout)

    def parse_simple_json(out):
        # Very basic parser for known SMN response keys
        # Returns a dict or fails if unexpected
        d = {}
        for line in out.splitlines():
            line = line.strip()
            if line.startswith('"') and line.find('":') != -1:
                k, v = line.split('":', 1)
                k = k.strip('"')
                v = v.strip().rstrip(',').strip('"')
                d[k] = v
        return d

    # Fetch existing topic if id is not provided: search by name
    def find_topic_by_name():
        # GET /notifications/topics
        res = smn_request("GET", base_url)
        if res == None:
            return None
        # Expect list of topics in 'topics' key
        topics = []
        # Simulated: hwc output contains "topics" as array of objects
        # Parse manually — assume JSON array of objects in stdout
        # For simplicity, we'll assume `hwc smn request` returns structured JSON per topic
        if res and "topics" in res:
            # Not robust, but required for translation — assume real system returns real JSON
            fail("SMN module requires real JSON parsing — hwc plugin missing")
        return None

    # Because Starlark cannot parse arbitrary JSON and we have no external tool,
    # we fallback: assume hwc CLI provides `topic show` or similar.
    # For production use, implement a real JSON parser or call jq if available.
    # Here, we assume the existence of a helper CLI: `smn-topic-show`
    def get_topic_by_id(tid):
        cmd = [
            "hwc", "smn", "topic", "show",
            "--identity-endpoint", identity_endpoint,
            "--domain", domain,
            "--project", project,
            "--region", region,
            "--user", user,
            "--password", password,
            tid
        ]
        res = ctx.run(cmd, mutates=False)
        if res.skipped:
            return None
        if res.rc != 0:
            if "not found" in res.stderr:
                return None
            fail("Failed to get topic: " + res.stderr)
        # Parse simple fields
        out = res.stdout.strip()
        # Return a dict with expected keys
        topic = {}
        for line in out.splitlines():
            if line.find("=") != -1:
                k, v = line.split("=", 1)
                topic[k.strip()] = v.strip()
        return topic

    # If id not provided, find by name
    if topic_id == None:
        # First, try to list topics and find by name
        # As Starlark has no JSON parser, assume we use `smn-topic-list` helper CLI
        cmd = [
            "hwc", "smn", "topic", "list",
            "--identity-endpoint", identity_endpoint,
            "--domain", domain,
            "--project", project,
            "--region", region,
            "--user", user,
            "--password", password
        ]
        res = ctx.run(cmd, mutates=False)
        if res.skipped:
            fail("Cannot list topics in check mode")
        if res.rc != 0:
            fail("Failed to list topics: " + res.stderr)

        # Parse simple output: "topic_urn\tname" per line
        lines = res.stdout.splitlines()
        found_ids = []
        for line in lines:
            parts = line.strip().split("\t")
            if len(parts) >= 2 and parts[1] == name:
                found_ids.append(parts[0])

        if len(found_ids) > 1:
            fail("Multiple topics with name %s found" % name)
        if len(found_ids) == 0:
            topic_id = None
        else:
            topic_id = found_ids[0]

    current = None
    if topic_id != None:
        current = get_topic_by_id(topic_id)

    # Check current state
    if state == "present":
        if current != None:
            # Already exists — check if update needed
            need_update = False
            if display_name != None and current.get("display_name") != display_name:
                need_update = True

            if need_update:
                # Update topic
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update topic %s" % name}
                cmd = [
                    "hwc", "smn", "topic", "update",
                    "--identity-endpoint", identity_endpoint,
                    "--domain", domain,
                    "--project", project,
                    "--region", region,
                    "--user", user,
                    "--password", password,
                    topic_id,
                    "--display-name", display_name if display_name != None else ""
                ]
                res = ctx.run(cmd, mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would update topic %s" % name}
                if res.rc != 0:
                    fail("Failed to update topic: " + res.stderr)
                return {"changed": True, "msg": "updated topic %s" % name, "data": current}
            else:
                return {"changed": False, "msg": "topic %s already exists" % name, "data": current}
        else:
            # Create topic
            if ctx.check_mode:
                return {"changed": True, "msg": "would create topic %s" % name}
            cmd = [
                "hwc", "smn", "topic", "create",
                "--identity-endpoint", identity_endpoint,
                "--domain", domain,
                "--project", project,
                "--region", region,
                "--user", user,
                "--password", password,
                "--name", name,
                "--display-name", display_name if display_name != None else ""
            ]
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would create topic %s" % name}
            if res.rc != 0:
                fail("Failed to create topic: " + res.stderr)
            # Parse output
            out = res.stdout.strip()
            topic_urn = ""
            for line in out.splitlines():
                if line.startswith("topic_urn="):
                    topic_urn = line.split("=", 1)[1]
            return {"changed": True, "msg": "created topic %s" % name, "data": {"topic_urn": topic_urn}}
    else:  # absent
        if current == None:
            return {"changed": False, "msg": "topic %s does not exist" % name}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete topic %s" % name}
            cmd = [
                "hwc", "smn", "topic", "delete",
                "--identity-endpoint", identity_endpoint,
                "--domain", domain,
                "--project", project,
                "--region", region,
                "--user", user,
                "--password", password,
                topic_id
            ]
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would delete topic %s" % name}
            if res.rc != 0:
                fail("Failed to delete topic: " + res.stderr)
            return {"changed": True, "msg": "deleted topic %s" % name}
