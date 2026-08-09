def _safe_json_decode(s):
    if not s or len(s) == 0:
        return None
    return json.decode(s)

_STATES = {
    1: ("OK", "Normal"),
    2: ("WARN", "Degraded"),
    3: ("CRIT", "Failed")
}

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        username = params.get("username", "3par_admin")
        password = params.get("password", "")
        port = params.get("port", 443)
        use_ssl = params.get("use_ssl", True)
        timeout = params.get("timeout", 10)

        curl_check = ctx.run(["curl", "--version"], mutates=False)
        if curl_check.rc != 0:
            return {"changed": False, "msg": "curl not found", "data": {"discovery": []}}

        scheme = "https" if use_ssl else "http"
        api_url = "%s://%s:%d/api/v1/cpgs" % (scheme, host, port)

        curl_cmd = [
            "curl", "-sk", "-u", "%s:%s" % (username, password),
            "--connect-timeout", str(timeout),
            "-H", "Accept: application/json",
            api_url
        ]
        res = ctx.run(curl_cmd, mutates=False)

        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "3PAR array not reachable or not accessible", "data": {"discovery": []}}

        data = _safe_json_decode(res.stdout)
        if data == None:
            return {"changed": False, "msg": "failed to parse 3PAR API response", "data": {"discovery": []}}

        members = data.get("members", []) if data else []
        if not members:
            return {"changed": False, "msg": "no CPGs found on 3PAR array", "data": {"discovery": []}}

        discovery = []
        for cpg in members:
            name = cpg.get("name")
            if name:
                state_val = cpg.get("state", 1)
                state_info = _STATES.get(state_val, ("UNKNOWN", "Unknown"))
                state_readable = state_info[1]
                discovery.append({
                    "item": name,
                    "params": {},
                    "metrics": ["num_vvs"],
                    "service_labels": {"3par_cpg_state": state_readable}
                })

        return {
            "changed": False,
            "msg": "discovered %d CPGs" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    username = params.get("username", "3par_admin")
    password = params.get("password", "")
    port = params.get("port", 443)
    use_ssl = params.get("use_ssl", True)
    timeout = params.get("timeout", 10)

    curl_check = ctx.run(["curl", "--version"], mutates=False)
    if curl_check.rc != 0:
        return {
            "changed": False,
            "msg": "curl not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "curl is required to query 3PAR array"}
        }

    scheme = "https" if use_ssl else "http"
    api_url = "%s://%s:%d/api/v1/cpgs" % (scheme, host, port)

    curl_cmd = [
        "curl", "-sk", "-u", "%s:%s" % (username, password),
        "--connect-timeout", str(timeout),
        "-H", "Accept: application/json",
        api_url
    ]
    res = ctx.run(curl_cmd, mutates=False)

    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "3PAR array not reachable or not accessible",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Cannot connect to 3PAR array at %s" % host}
        }

    data = _safe_json_decode(res.stdout)
    if data == None:
        return {
            "changed": False,
            "msg": "failed to parse 3PAR API response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    members = data.get("members", []) if data else []

    found_cpg = None
    for cpg in members:
        if cpg.get("name") == item:
            found_cpg = cpg
            break

    if found_cpg == None:
        return {
            "changed": False,
            "msg": "no such CPG: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "CPG %s not found on array" % item}
        }

    state_val = found_cpg.get("state", 1)
    state_info = _STATES.get(state_val, ("UNKNOWN", "Unknown"))
    state_code = state_info[0]
    state_readable = state_info[1]

    num_fpvvs = cpg_get_int(found_cpg.get("numFPVVs"))
    num_tdvvs = cpg_get_int(found_cpg.get("numTDVVs"))
    num_tpvvs = cpg_get_int(found_cpg.get("numTPVVs"))
    total_vvs = num_fpvvs + num_tdvvs + num_tpvvs

    msg = "%s, %d VVs" % (state_readable, total_vvs)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_code,
            "metrics": {"num_vvs": total_vvs},
            "details": msg
        }
    }

def cpg_get_int(v):
    if v == None:
        return 0
    if type(v) == "int":
        return v
    if type(v) == "string":
        return int(v) if v.isdigit() else 0
    return 0