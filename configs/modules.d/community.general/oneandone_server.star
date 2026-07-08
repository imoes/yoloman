def main(ctx, params):
    # Extract parameters
    state = params.get("state", "present")
    auth_token = params.get("auth_token")
    api_url = params.get("api_url")
    server_id = params.get("server")
    hostname = params.get("hostname")
    appliance = params.get("appliance")
    datacenter = params.get("datacenter", "US")
    count = params.get("count", 1)
    wait = params.get("wait", True)
    wait_timeout = params.get("wait_timeout", 600)
    wait_interval = params.get("wait_interval", 5)
    auto_increment = params.get("auto_increment", True)

    # Environment variable fallbacks for auth
    facts = ctx.facts()
    if auth_token == None:
        env = facts.get("env", {})
        if type(env) == "dict":
            auth_token = env.get("ONEANDONE_AUTH_TOKEN")
    if api_url == None:
        env = facts.get("env", {})
        if type(env) == "dict":
            api_url = env.get("ONEANDONE_API_URL")

    # Required checks per state
    if state == "absent" and server_id == None:
        fail("server parameter is required for deleting a server.")
    if state in ("running", "stopped") and server_id == None:
        fail("server parameter is required for starting/stopping a server.")
    if state == "present":
        for required in ("hostname", "appliance", "datacenter"):
            if params.get(required) == None:
                fail("%s parameter is required for new server." % required)

    # Auth token required
    if auth_token == None:
        fail("The auth_token parameter or ONEANDONE_AUTH_TOKEN environment variable is required.")

    # Build base API URL
    url = api_url if api_url != None else "https://api.1and1.com/v1"
    headers = {
        "Authorization": "Token " + auth_token,
        "Content-Type": "application/json"
    }

    # Helper to perform HTTP calls via ctx.run (curl)
    def http(method, path, data=None):
        body = ""
        if data != None:
            body = _to_json(data)
        url_full = url.rstrip("/") + "/" + path.lstrip("/")
        argv = ["curl", "-sS", "-X", method, "-H", "Authorization: Token " + auth_token]
        if data != None:
            argv += ["-H", "Content-Type: application/json", "-d", body]
        argv.append(url_full)
        res = ctx.run(argv, mutates=(method != "GET"))
        if res.skipped:
            return None  # check_mode only
        if res.rc != 0:
            fail("API call failed: " + res.stderr)
        if res.stdout == "":
            return {}
        return _from_json(res.stdout)

    # Datacenter lookup
    def lookup_datacenter(dc_name):
        data = http("GET", "/datacenters")
        if data == None:
            return None
        for dc in data.get("datacenters", []):
            if dc.get("name") == dc_name or dc.get("id") == dc_name:
                return dc.get("id")
        return None

    # Appliance lookup
    def lookup_appliance(appliance_name):
        data = http("GET", "/appliances")
        if data == None:
            return None
        for ap in data.get("appliances", []):
            if ap.get("name") == appliance_name or ap.get("id") == appliance_name:
                return ap.get("id")
        return None

    # Server lookup
    def lookup_server(server_ref):
        data = http("GET", "/servers")
        if data == None:
            return None
        for sv in data.get("servers", []):
            if sv.get("name") == server_ref or sv.get("id") == server_ref:
                return sv
        return None

    # Helper: wait for server state
    def wait_for_server_state(sv_id, target_state, timeout, interval):
        elapsed = 0
        while elapsed < timeout:
            sv = http("GET", "/servers/" + sv_id)
            if sv == None:
                return False
            state_name = sv.get("status", {}).get("state", "")
            if target_state == "POWERED_ON" and state_name == "POWERED_ON":
                return True
            if target_state == "POWERED_OFF" and state_name == "POWERED_OFF":
                return True
            # Sleep using shell command
            ctx.run(["sleep", str(interval)])
            elapsed += interval
        return False

    # Helper: auto increment hostnames/descriptions
    def auto_increment_list(fmt, count):
        if fmt == None:
            return [""] * count
        if fmt.find("%") == -1:
            out = []
            for i in range(1, count + 1):
                out.append(fmt + "-" + str(i))
            return out
        out = []
        for i in range(1, count + 1):
            out.append(fmt % i)
        return out

    # Actual state handling
    if state == "absent":
        sv = lookup_server(server_id)
        if sv == None:
            return {"changed": False, "msg": "server %s not found" % server_id}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete server %s" % server_id}
        res = http("DELETE", "/servers/" + sv["id"])
        if res == None:
            return {"changed": True, "msg": "would delete server %s" % server_id}
        if wait:
            if not wait_for_server_state(sv["id"], "POWERED_OFF", wait_timeout, wait_interval):
                fail("timeout waiting for server deletion")
        return {"changed": True, "msg": "server %s deleted" % sv["name"], "data": {"id": sv["id"], "hostname": sv["name"]}}

    if state in ("running", "stopped"):
        sv = lookup_server(server_id)
        if sv == None:
            fail("server %s not found" % server_id)
        current = sv.get("status", {}).get("state", "")
        target = "POWERED_ON" if state == "running" else "POWERED_OFF"
        if current == target:
            return {"changed": False, "msg": "server %s already %s" % (sv["name"], state)}
        if ctx.check_mode:
            return {"changed": True, "msg": "would set server %s to %s" % (sv["name"], state)}
        action = "POWER_ON" if state == "running" else "POWER_OFF"
        payload = {"action": action, "method": "SOFTWARE"}
        res = http("PUT", "/servers/" + sv["id"] + "/status", payload)
        if res == None:
            return {"changed": True, "msg": "would set server %s to %s" % (sv["name"], state)}
        if wait:
            if not wait_for_server_state(sv["id"], target, wait_timeout, wait_interval):
                fail("timeout waiting for server to reach %s" % state)
        return {"changed": True, "msg": "server %s set to %s" % (sv["name"], state), "data": {"id": sv["id"], "hostname": sv["name"]}}

    if state == "present":
        dc_id = lookup_datacenter(datacenter)
        if dc_id == None:
            fail("datacenter %s not found" % datacenter)
        app_id = lookup_appliance(appliance)
        if app_id == None:
            fail("appliance %s not found" % appliance)

        hostnames = auto_increment_list(hostname, count)
        descriptions = auto_increment_list(params.get("description"), count)
        hdds = params.get("hdds") or []
        hdd_objs = []
        for hdd in hdds:
            hdd_objs.append({"size": int(hdd.get("size", 0)), "is_main": bool(hdd.get("is_main", False))})

        fixed_instance_size_id = None
        if params.get("fixed_instance_size"):
            fixed_sizes = ["S", "M", "L", "XL", "XXL", "3XL", "4XL", "5XL"]
            if params.get("fixed_instance_size") not in fixed_sizes:
                fail("invalid fixed_instance_size: %s" % params.get("fixed_instance_size"))
            fixed_instance_size_id = params.get("fixed_instance_size")

        servers_result = []
        for idx, name in enumerate(hostnames):
            payload = {
                "name": name,
                "description": descriptions[idx] if descriptions[idx] != "" else None,
                "appliance_id": app_id,
                "datacenter_id": dc_id,
                "server_type": params.get("server_type", "cloud")
            }
            if fixed_instance_size_id != None:
                payload["fixed_instance_size_id"] = fixed_instance_size_id
            else:
                payload["vcore"] = params.get("vcore")
                payload["cores_per_processor"] = params.get("cores_per_processor")
                payload["ram"] = str(params.get("ram"))
                payload["hdds"] = hdd_objs
            if params.get("ssh_key"):
                payload["rsa_key"] = params.get("ssh_key")

            if ctx.check_mode:
                servers_result.append({"name": name, "id": "dry-run-id", "public_ipv4": "0.0.0.0"})
                continue

            res = http("POST", "/servers", payload)
            if res == None:
                servers_result.append({"name": name, "id": "dry-run-id", "public_ipv4": "0.0.0.0"})
                continue

            sv_id = res.get("id")
            if sv_id != None and wait:
                if not wait_for_server_state(sv_id, "POWERED_ON", wait_timeout, wait_interval):
                    fail("timeout waiting for server %s to become running" % name)

            sv = {}
            if sv_id != None:
                sv = http("GET", "/servers/" + sv_id)

            # Add IP data
            public_ipv4 = "0.0.0.0"
            public_ipv6 = ""
            for ip in sv.get("ips", []):
                if ip.get("type") == "IPV4":
                    public_ipv4 = ip.get("ip", "0.0.0.0")
                if ip.get("type") == "IPV6":
                    public_ipv6 = ip.get("ip", "")
            servers_result.append({
                "hostname": name,
                "id": sv_id,
                "public_ipv4": public_ipv4,
                "public_ipv6": public_ipv6
            })

        changed = True
        return {"changed": changed, "msg": "servers created", "data": {"servers": servers_result}}


def _to_json(obj):
    if type(obj) == "dict":
        items = []
        for k, v in obj.items():
            items.append('"%s": %s' % (k, _to_json(v)))
        return "{" + ", ".join(items) + "}"
    if type(obj) == "list":
        return "[" + ", ".join([_to_json(x) for x in obj]) + "]"
    if type(obj) == "bool":
        return "true" if obj else "false"
    if type(obj) == "int" or type(obj) == "float":
        return str(obj)
    if obj == None:
        return "null"
    escaped = str(obj).replace("\\", "\\\\").replace("\"", "\\\"")
    return "\"" + escaped + "\""


def _from_json(s):
    s = s.strip()
    if s == "{}":
        return {}
    if s == "[]":
        return []
    if s.startswith("{") and s.endswith("}"):
        inner = s[1:-1].strip()
        if inner == "":
            return {}
        result = {}
        depth = 0
        current = ""
        i = 0
        while i < len(inner):
            c = inner[i]
            if c == '{' or c == '[':
                depth += 1
                current += c
            elif c == '}' or c == ']':
                depth -= 1
                current += c
            elif c == ',' and depth == 0:
                if current.strip() != "":
                    key, val = _split_pair(current)
                    result[key] = _parse_value(val.strip())
                current = ""
            else:
                current += c
            i += 1
        if current.strip() != "":
            key, val = _split_pair(current)
            result[key] = _parse_value(val.strip())
        return result
    return {}


def _split_pair(s):
    idx = s.find(":")
    if idx == -1:
        return ("", s)
    key = s[:idx].strip()
    val = s[idx + 1:]
    if key.startswith("\"") and key.endswith("\""):
        key = key[1:-1].replace("\\\"", "\"")
    return (key, val)


def _parse_value(val):
    if val == "true":
        return True
    if val == "false":
        return False
    if val.startswith("\"") and val.endswith("\""):
        return val[1:-1].replace("\\\"", "\"")
    if val.isdigit():
        return int(val)
    if val.replace(".", "").isdigit() and val.count(".") == 1:
        return float(val)
    return val
