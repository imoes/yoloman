CURL_TIMEOUT = "10"

def _get_xml_prop(xml, prop_name):
    search = 'name="' + prop_name + '">'
    idx = xml.find(search)
    if idx == -1:
        return ""
    start = idx + len(search)
    end = xml.find("</PROPERTY>", start)
    if end == -1:
        return ""
    return xml[start:end].strip()

def _parse_controller_objects(xml):
    objects = []
    parts = xml.split("<OBJECT ")
    for part in parts[1:]:
        obj = {}
        prop_parts = part.split("<PROPERTY ")
        for pp in prop_parts[1:]:
            name_idx = pp.find('name="')
            if name_idx == -1:
                continue
            name_idx += 6
            name_end = pp.find('"', name_idx)
            if name_end == -1:
                continue
            prop_name = pp[name_idx:name_end]
            val_start = pp.find(">")
            if val_start == -1:
                continue
            val_start += 1
            val_end = pp.find("</PROPERTY>", val_start)
            if val_end == -1:
                continue
            obj[prop_name] = pp[val_start:val_end].strip()
        if "durable-id" in obj:
            objects.append(obj)
    return objects

def _login(ctx, host, username, password):
    cred = username + "_" + password
    md5_res = ctx.run(
        ["python3", "-c",
         "import hashlib, sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())",
         cred],
        mutates=False,
    )
    if md5_res.rc != 0:
        fail("md5 computation failed: " + md5_res.stderr)
    md5_hash = md5_res.stdout.strip()

    login_res = ctx.run(
        ["curl", "-k", "-s", "-m", CURL_TIMEOUT,
         "https://" + host + "/api/login/" + md5_hash],
        mutates=False,
    )
    if login_res.rc != 0:
        fail("login request failed: " + login_res.stderr)

    resp_type = _get_xml_prop(login_res.stdout, "response-type")
    if resp_type != "success":
        fail("login rejected: " + resp_type)

    session_key = _get_xml_prop(login_res.stdout, "response")
    if not session_key:
        fail("no session key in login response")
    return session_key

def _api_get(ctx, host, session_key, endpoint):
    res = ctx.run(
        ["curl", "-k", "-s", "-m", CURL_TIMEOUT,
         "-H", "sessionKey: " + session_key,
         "https://" + host + "/api/" + endpoint],
        mutates=False,
    )
    if res.rc != 0:
        fail("API request failed for " + endpoint + ": " + res.stderr)
    return res.stdout

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "monitor")
    password = params.get("password", "")
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)

    session_key = _login(ctx, host, username, password)
    xml = _api_get(ctx, host, session_key, "show/controller-statistics")
    controllers = _parse_controller_objects(xml)

    if params.get("_discover"):
        discovery = []
        for c in controllers:
            item = c.get("durable-id", "")
            if item:
                discovery.append({
                    "item": item,
                    "params": {"warn": 80.0, "crit": 90.0},
                    "metrics": ["util"],
                })
        return {
            "changed": False,
            "msg": "discovered %d controllers" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    target = None
    for c in controllers:
        if c.get("durable-id") == item:
            target = c
            break

    if target == None:
        return {
            "changed": False,
            "msg": "controller not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    cpu_str = target.get("cpu-load", "")
    if not cpu_str:
        return {
            "changed": False,
            "msg": "cpu-load not available for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    is_num = cpu_str.replace(".", "", 1).isdigit()
    cpu_load = float(cpu_str) if is_num else 0.0

    if cpu_load >= crit:
        state = "CRIT"
    elif cpu_load >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "CPU %s: %f%%" % (item, cpu_load),
        "data": {
            "state": state,
            "metrics": {"util": cpu_load},
            "details": "",
        },
    }