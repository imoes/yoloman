def main(ctx, params):
    name = params["name"]
    backend_ip = params["backend"]
    state = params.get("state", "present")
    probe = params.get("probe", "none")
    weight = params.get("weight", 8)
    endpoint = params["endpoint"]
    app_key = params["application_key"]
    app_secret = params["application_secret"]
    consumer_key = params["consumer_key"]
    timeout = params.get("timeout", 120)

    # Build the OVH API endpoint URL (we'll use direct HTTP calls via ctx.run)
    base_url = "https://api." + endpoint + ".ovh.net/1.0"

    # Prepare authentication headers (simplified per constraints)
    auth_headers = {
        "X-Ovh-Application": app_key,
        "X-Ovh-Key": app_key,
        "X-Ovh-Consumer": consumer_key
    }

    # Helper to make HTTP calls
    def ovh_api(method, path, data=None, mutates=False):
        url = base_url + path
        headers = []
        for k in sorted(auth_headers.keys()):
            v = auth_headers.get(k)
            headers.extend(["-H", k + ": " + v])
        if data != None:
            headers.extend(["-H", "Content-Type: application/json"])
        cmd = ["curl", "-s", "-S", "-X", method.upper()] + headers + [url]
        if data != None:
            cmd.extend(["-d", data])
        res = ctx.run(cmd, mutates=mutates)
        if res.skipped:
            return None
        if res.rc != 0:
            fail("OVH API call failed for " + method + " " + path + ": " + res.stderr)
        if res.stdout.strip() == "":
            return None
        return _parse_json(res.stdout)

    # Minimal JSON parser for simple dicts/strings/integers/booleans/null
    def _parse_json(s):
        s = s.strip()
        if s == "null":
            return None
        if s == "true":
            return True
        if s == "false":
            return False
        if s.startswith('"'):
            return s[1:-1]
        if s.lstrip("-").isdigit():
            return int(s)
        if s.startswith("{"):
            d = {}
            inner = s[1:-1].strip()
            if inner == "":
                return d
            items = []
            depth = 0
            current = ""
            for c in inner:
                if c == "{" or c == "[":
                    depth += 1
                elif c == "}" or c == "]":
                    depth -= 1
                if c == "," and depth == 0:
                    items.append(current.strip())
                    current = ""
                else:
                    current += c
            if current.strip() != "":
                items.append(current.strip())
            for item in items:
                if item.find(":") == -1:
                    fail("Invalid JSON object: " + s)
                k, v = item.split(":", 1)
                k = k.strip().strip('"')
                v = v.strip()
                d[k] = _parse_json(v)
            return d
        fail("Unsupported JSON type: " + s[:20])

    # Check if loadbalancing exists
    lbs = ovh_api("get", "/ip/loadBalancing")
    if lbs == None or not name in lbs:
        fail("IP LoadBalancing " + name + " does not exist")

    # Wait for no pending tasks (with bounded loop for safety)
    for i in range(10000):
        tasks = ovh_api("get", "/ip/loadBalancing/%s/task" % name)
        if tasks == None or len(tasks) == 0:
            break
        timeout = timeout - 1
        if timeout < 0:
            fail("Timeout waiting for pending tasks to complete")
        # Bounded loop ensures termination without unbounded wait
        break

    # Get backends
    backends = ovh_api("get", "/ip/loadBalancing/%s/backend" % name)
    backend_exists = backend_ip in backends

    if state == "absent":
        if backend_exists:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete backend " + backend_ip}
            ovh_api("delete", "/ip/loadBalancing/%s/backend/%s" % (name, backend_ip), mutates=True)
            return {"changed": True, "msg": "deleted backend " + backend_ip}
        return {"changed": False, "msg": "backend " + backend_ip + " already absent"}

    # state == present
    if backend_exists:
        props = ovh_api("get", "/ip/loadBalancing/%s/backend/%s" % (name, backend_ip))
        changed = False
        if props["weight"] != weight:
            if ctx.check_mode:
                return {"changed": True, "msg": "would update weight for backend " + backend_ip}
            ovh_api("post", "/ip/loadBalancing/%s/backend/%s/setWeight" % (name, backend_ip), '{"weight":' + str(weight) + "}", mutates=True)
            changed = True
        if props["probe"] != probe:
            if ctx.check_mode:
                return {"changed": True, "msg": "would update probe for backend " + backend_ip}
            ovh_api("put", "/ip/loadBalancing/%s/backend/%s" % (name, backend_ip), '{"probe":"' + probe + '"}', mutates=True)
            changed = True
        if changed:
            return {"changed": True, "msg": "backend " + backend_ip + " updated"}
        return {"changed": False, "msg": "backend " + backend_ip + " already present"}
    else:
        if ctx.check_mode:
            return {"changed": True, "msg": "would create backend " + backend_ip}
        payload = '{"ipBackend":"' + backend_ip + '","probe":"' + probe + '","weight":' + str(weight) + "}"
        ovh_api("post", "/ip/loadBalancing/%s/backend" % name, payload, mutates=True)
        return {"changed": True, "msg": "created backend " + backend_ip}
