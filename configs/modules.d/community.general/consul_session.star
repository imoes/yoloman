def main(ctx, params):
    # Extract parameters
    state = params.get("state", "present")
    name = params.get("name")
    session_id = params.get("id")
    delay = params.get("delay", 15)
    node = params.get("node")
    datacenter = params.get("datacenter")
    checks = params.get("checks", [])
    behavior = params.get("behavior", "release")
    ttl = params.get("ttl")
    token = params.get("token")
    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    validate_certs = params.get("validate_certs", True)
    ca_path = params.get("ca_path")

    # Validate required parameters for specific states
    if state == "node" and not name:
        fail("state 'node' requires 'name'")
    if state in ("info", "absent") and not session_id:
        fail("state '%s' requires 'id'" % state)

    # Build base URL
    base_url = scheme + "://" + host + ":" + str(port)

    # Build headers
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Consul-Token"] = token

    # Build query params
    params_query = {}
    if datacenter:
        params_query["dc"] = datacenter
    if not validate_certs:
        fail("validate_certs=false is not supported; always verify TLS")
    if ca_path:
        fail("ca_path is not supported; use system CA store")

    # Helper: build full URL path
    def url(path):
        return base_url + "/v1/" + path

    # Helper: run HTTP request
    def http(method, path, data=None):
        cmd = ["curl", "-s", "-f", "-X", method, url(path)]
        if data:
            cmd.extend(["-d", data])
        for k, v in headers.items():
            cmd.extend(["-H", k + ":" + v])
        for k, v in params_query.items():
            cmd.extend(["-G", "--data-urlencode", k + "=" + v])
        if not validate_certs:
            cmd.append("-k")  # skip cert verification
        if ca_path:
            fail("ca_path not supported")
        res = ctx.run(cmd, mutates=(method != "GET"))
        if res.rc != 0 and not res.skipped:
            fail("HTTP error: " + res.stderr)
        return res

    # List sessions (GET /v1/session/list)
    def list_sessions():
        res = http("GET", "session/list")
        if res.skipped:
            return ""
        return res.stdout

    # List sessions for node (GET /v1/session/node/{node})
    def list_sessions_for_node(node_name):
        res = http("GET", "session/node/" + node_name)
        if res.skipped:
            return ""
        return res.stdout

    # Get session info by id (GET /v1/session/info/{id})
    def get_session_info(session_id_val):
        res = http("GET", "session/info/" + session_id_val)
        if res.skipped:
            return ""
        return res.stdout

    # Helper: create session payload as simple string (avoid json.dumps)
    def build_create_data():
        # Build minimal JSON manually
        lines = []
        lines.append("{")
        lines.append("\"LockDelay\": " + str(delay) + ",")
        if node:
            lines.append("\"Node\": \"" + node + "\",")
        lines.append("\"Name\": \"" + name + "\",")
        if checks:
            lines.append("\"Checks\": " + str(checks) + ",")
        lines.append("\"Behavior\": \"" + behavior + "\"")
        if ttl != None:
            lines.append(",\"TTL\": \"" + str(ttl) + "s\"")
        lines.append("}")
        return "".join(lines)

    # Create session (PUT /v1/session/create)
    def create_session():
        data_str = build_create_data()
        res = http("PUT", "session/create", data_str)
        if res.skipped:
            return ""
        return res.stdout

    # Destroy session (PUT /v1/session/destroy/{id})
    def destroy_session(session_id_val):
        res = http("PUT", "session/destroy/" + session_id_val)
        if res.skipped:
            return ""
        return res.stdout

    # Parse JSON result for session ID (naive but safe for known shape)
    def extract_session_id(json_str):
        # Look for "ID":"<id>" pattern
        key = "\"ID\""
        idx = json_str.find(key)
        if idx == -1:
            return ""
        start = json_str.find(":", idx)
        if start == -1:
            return ""
        i = start + 1
        while i < len(json_str) and json_str[i] in " \t\n\r":
            i += 1
        if i >= len(json_str):
            return ""
        if json_str[i] == '"':
            i += 1
            j = i
            while j < len(json_str) and json_str[j] != '"':
                if json_str[j] == '\\' and j + 1 < len(json_str):
                    j += 2
                else:
                    j += 1
            return json_str[i:j]
        else:
            return ""

    # Execute based on state
    if state == "list":
        if ctx.check_mode:
            return {"changed": False, "msg": "would list sessions", "sessions": []}
        sessions_json = list_sessions()
        return {"changed": False, "msg": "sessions listed", "sessions": sessions_json}

    elif state == "node":
        if not name:
            fail("state 'node' requires 'name'")
        if ctx.check_mode:
            return {"changed": False, "msg": "would list sessions for node", "sessions": []}
        sessions_json = list_sessions_for_node(name)
        return {"changed": False, "msg": "sessions for node listed", "node": name, "sessions": sessions_json}

    elif state == "info":
        if not session_id:
            fail("state 'info' requires 'id'")
        if ctx.check_mode:
            return {"changed": False, "msg": "would get session info", "session_id": session_id, "sessions": []}
        sessions_json = get_session_info(session_id)
        return {"changed": False, "msg": "session info retrieved", "session_id": session_id, "sessions": sessions_json}

    elif state == "present":
        if not name:
            fail("state 'present' requires 'name'")
        if ctx.check_mode:
            # Predict changed if creation would happen (always true here)
            return {"changed": True, "msg": "would create session", "name": name}
        created_json = create_session()
        sid = extract_session_id(created_json)
        if not sid:
            fail("failed to create session: no ID in response")
        return {"changed": True, "msg": "session created", "session_id": sid, "name": name, "behavior": behavior}

    elif state == "absent":
        if ctx.check_mode:
            return {"changed": True, "msg": "would destroy session", "session_id": session_id}
        destroy_session(session_id)
        return {"changed": True, "msg": "session destroyed", "session_id": session_id}

    else:
        fail("unsupported state: " + state)
